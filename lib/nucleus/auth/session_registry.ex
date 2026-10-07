defmodule Nucleus.Auth.SessionRegistry do
  @moduledoc """
  The shared clock behind `AUTH-A08` and the status behind `AUTH-A05`.

  ## Why this exists

  A LiveView socket cannot write a `Set-Cookie`, so socket activity cannot
  advance an idle clock kept in the session cookie. This process holds that
  clock instead: one record per signed-in session, keyed by session id, fed by
  HTTP requests, LiveView mounts, navigation and (throttled) events. It also
  decides when a session ends and tells every open tab.

  ## What a record holds

  `%{id, user, tenant, signed_in_at, last_active, path, idle_ms, max_age_ms, status}`,
  timestamps in milliseconds, `path` the last page the session was seen on
  (see "Where the user was" below), `status` one of:

  - `:active`
  - `{:expired, :idle | :max_age | :user}` - ended; `:user` is a sign-out
  - `:terminated` - ended by another user (`AUTH-A13`; nothing in `AUTH-S1`
    sets it, `terminate_session/2` is the seam that ticket will call)

  Reads go straight to ETS in the caller's process. Every write goes through
  this process, which is what makes `expire/3` atomic.

  ## Where the user was (`AUTH-A09`)

  When a connected tab's session ends, the user is sent to sign in and then
  back to "the page they were on". The reconnect that discovers the expiry
  cannot say what that page was - a LiveView mount sees no page URL - so the
  registry remembers it: every navigation reports its path through `touch/3`,
  and `last_path/2` hands it to whoever redirects to sign-in. It is kept on
  the ended record, so it is still there when the tab comes back.

  ## Expiry happens exactly once

  A session can be found expired by three parties at about the same moment: its
  own timer, an HTTP request, a LiveView mount. `expire/3` is the single
  transition out of `:active`; it returns `{:ok, record}` to the one caller that
  made the transition and `:already` to everyone else, and only the first
  announces (`announce_expiry/2`: the `sign_out` audit event plus a
  `"disconnect"` broadcast that closes every tab on the session's
  `live_socket_id`).

  ## The timer is lazy

  Each session has one timer, set to its first possible deadline. Activity does
  not reschedule it; when it fires it recomputes the real deadline from
  `last_active` and, if the session was active in the meantime, sleeps again.
  So a busy session costs one ETS write per touch, not a timer churn.

  ## Limits of this design (`docs/adr/0040-cognito-sign-in-and-session-lifecycle.md`)

  - **Single node.** State is per node. If Nucleus ever scales out, sticky
    sessions keep a user's requests on the node that holds their record.
  - **A restart forgets everything.** A session the registry has not heard of
    falls back to the timestamps in its cookie (`Nucleus.Auth.SessionCheck`),
    which can only err towards signing out early. A *terminated* session is
    forgotten too, so its cookie works again until it ages out - a gap for
    `AUTH-A13`'s ticket to close.
  - Records are pruned once `max_age` has passed, since the cookie's own
    `signed_in_at` ends the session by then regardless of anything here.
  """

  use GenServer

  alias Nucleus.Audit
  alias Nucleus.Auth.{Config, Session}

  @prune_interval :timer.minutes(1)

  @type id :: String.t()
  @type status ::
          :active
          | {:expired, :idle | :max_age | :user}
          | :terminated
          | :unknown

  @type attrs :: %{
          required(:id) => id(),
          required(:user) => String.t(),
          required(:tenant) => String.t() | nil,
          required(:signed_in_at) => integer(),
          optional(:last_active) => integer()
        }

  # --- client API -----------------------------------------------------------

  @doc """
  Options:

  - `:name` - registered name and ETS table name (default `#{inspect(__MODULE__)}`)
  - `:on_expire` - `(record, reason -> any)` run in a supervised task when a
    timer ends a session (default `announce_expiry/2`)
  - `:idle_ms`, `:max_age_ms` - override `Nucleus.Auth.Config`, for fast tests
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Starts tracking a session. `attrs` times are in milliseconds; `:last_active`
  defaults to `:signed_in_at`.
  """
  @spec register(attrs(), GenServer.name()) :: :ok
  def register(attrs, server \\ __MODULE__), do: GenServer.call(server, {:register, attrs})

  @doc """
  Records activity, and the `path` the session is now on if given. A no-op on a
  session that has ended or is already past a deadline.
  """
  @spec touch(id(), String.t() | nil, GenServer.name()) :: :ok
  def touch(id, path \\ nil, server \\ __MODULE__) do
    GenServer.cast(server, {:touch, id, path})
  end

  @doc "The last path `touch/3` reported for the session, ended or not; `nil` if none."
  @spec last_path(id(), GenServer.name()) :: String.t() | nil
  def last_path(id, server \\ __MODULE__) do
    case :ets.lookup(server, id) do
      [{^id, record}] -> record.path
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  The session's status right now. A session past a deadline reads as expired
  even before its timer or an `expire/3` call has recorded it.
  """
  @spec status(id(), GenServer.name()) :: status()
  def status(id, server \\ __MODULE__) do
    case :ets.lookup(server, id) do
      [{^id, record}] -> classify(record, now_ms())
      [] -> :unknown
    end
  rescue
    ArgumentError -> :unknown
  end

  @doc """
  Moves a session from active to expired. The one atomic transition (see the
  moduledoc): `{:ok, record}` for the caller that made it, `:already` for any
  later caller. Works on a session the registry has not heard of, recording it
  as ended from `attrs` so that a stale cookie replayed after a restart cannot
  announce the same expiry twice.
  """
  @spec expire(attrs(), :idle | :max_age | :user, GenServer.name()) ::
          {:ok, map()} | :already
  def expire(attrs, reason, server \\ __MODULE__) when reason in [:idle, :max_age, :user] do
    GenServer.call(server, {:expire, attrs, reason})
  end

  @doc """
  Marks a session terminated by another user. The seam for `AUTH-A13`; nothing
  in `AUTH-S1` calls it. Returns `:unknown` for a session the registry does not hold.
  """
  @spec terminate_session(id(), GenServer.name()) :: :ok | :unknown
  def terminate_session(id, server \\ __MODULE__), do: GenServer.call(server, {:terminate, id})

  @doc """
  Announces that a session ended: the `sign_out` audit event, then a
  `"disconnect"` broadcast that closes every tab on its `live_socket_id`.

  Runs in the caller's process, which is what lets a request handler's audit
  event land in the same place as every other one.
  """
  @spec announce_expiry(map(), :idle | :max_age | :user) :: :ok
  def announce_expiry(%{id: id, user: user, tenant: tenant}, reason) do
    Audit.emit(:sign_out, user: user, tenant: tenant, reason: Atom.to_string(reason))
    NucleusWeb.Endpoint.broadcast(Session.live_socket_id(id), "disconnect", %{})
    :ok
  end

  # --- server ---------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    :ets.new(name, [:set, :protected, :named_table, read_concurrency: true])
    schedule_prune()

    {:ok,
     %{
       table: name,
       timers: %{},
       on_expire: Keyword.get(opts, :on_expire, &__MODULE__.announce_expiry/2),
       idle_ms: Keyword.get(opts, :idle_ms),
       max_age_ms: Keyword.get(opts, :max_age_ms)
     }}
  end

  @impl GenServer
  def handle_call({:register, attrs}, _from, state) do
    now = now_ms()
    record = new_record(attrs, state, now)
    :ets.insert(state.table, {record.id, record})
    {:reply, :ok, schedule(state, record, now)}
  end

  def handle_call({:expire, attrs, reason}, _from, state) do
    now = now_ms()

    case :ets.lookup(state.table, attrs.id) do
      [] ->
        record = %{new_record(attrs, state, now) | status: {:expired, reason}}
        :ets.insert(state.table, {record.id, record})
        {:reply, {:ok, record}, state}

      [{_id, %{status: :active} = record}] ->
        record = %{record | status: {:expired, reason}}
        :ets.insert(state.table, {record.id, record})
        {:reply, {:ok, record}, cancel_timer(state, record.id)}

      [_ended] ->
        {:reply, :already, state}
    end
  end

  def handle_call({:terminate, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, record}] ->
        :ets.insert(state.table, {id, %{record | status: :terminated}})
        {:reply, :ok, cancel_timer(state, id)}

      [] ->
        {:reply, :unknown, state}
    end
  end

  @impl GenServer
  def handle_cast({:touch, id, path}, state) do
    now = now_ms()

    with [{^id, %{status: :active} = record}] <- :ets.lookup(state.table, id),
         :active <- classify(record, now) do
      :ets.insert(state.table, {id, %{record | last_active: now, path: path || record.path}})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:deadline, id}, state) do
    state = %{state | timers: Map.delete(state.timers, id)}
    now = now_ms()

    with [{^id, %{status: :active} = record}] <- :ets.lookup(state.table, id) do
      case classify(record, now) do
        {:expired, reason} ->
          :ets.insert(state.table, {id, %{record | status: {:expired, reason}}})
          run_on_expire(state.on_expire, record, reason)
          {:noreply, state}

        :active ->
          {:noreply, schedule(state, record, now)}
      end
    else
      _ended_or_gone -> {:noreply, state}
    end
  end

  def handle_info(:prune, state) do
    now = now_ms()

    :ets.foldl(
      fn {id, record}, :ok ->
        if now >= record.signed_in_at + record.max_age_ms, do: :ets.delete(state.table, id)
        :ok
      end,
      :ok,
      state.table
    )

    schedule_prune()
    {:noreply, state}
  end

  # Anything else (a stray reply, a late timer for a session that is gone) is not
  # worth taking every session's clock down for.
  def handle_info(_other, state), do: {:noreply, state}

  # --- internals ------------------------------------------------------------

  defp new_record(attrs, state, now) do
    signed_in_at = Map.get(attrs, :signed_in_at, now)

    %{
      id: attrs.id,
      user: attrs.user,
      tenant: attrs.tenant,
      signed_in_at: signed_in_at,
      last_active: Map.get(attrs, :last_active, signed_in_at),
      path: nil,
      idle_ms: state.idle_ms || Config.idle_timeout() * 1000,
      max_age_ms: state.max_age_ms || Config.max_age() * 1000,
      status: :active
    }
  end

  defp classify(%{status: :active} = record, now) do
    cond do
      now >= record.signed_in_at + record.max_age_ms -> {:expired, :max_age}
      now >= record.last_active + record.idle_ms -> {:expired, :idle}
      true -> :active
    end
  end

  defp classify(%{status: {:expired, _reason} = expired}, _now), do: expired
  defp classify(%{status: :terminated}, _now), do: :terminated

  defp deadline(record) do
    min(record.last_active + record.idle_ms, record.signed_in_at + record.max_age_ms)
  end

  defp schedule(state, record, now) do
    state = cancel_timer(state, record.id)
    ref = Process.send_after(self(), {:deadline, record.id}, max(deadline(record) - now, 0))
    %{state | timers: Map.put(state.timers, record.id, ref)}
  end

  defp cancel_timer(state, id) do
    case Map.pop(state.timers, id) do
      {nil, _timers} ->
        state

      {ref, timers} ->
        Process.cancel_timer(ref)
        %{state | timers: timers}
    end
  end

  # A failing audit write must not take the registry (and every session's
  # clock) down with it, so the announcement runs in its own supervised task.
  defp run_on_expire(on_expire, record, reason) do
    Task.Supervisor.start_child(Nucleus.TaskSupervisor, fn -> on_expire.(record, reason) end)
  end

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval)

  defp now_ms, do: System.system_time(:millisecond)
end
