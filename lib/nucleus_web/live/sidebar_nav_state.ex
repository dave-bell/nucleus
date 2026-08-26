defmodule NucleusWeb.SidebarNavState do
  @moduledoc """
  Shared, in-memory store for the sidebar's `:expanded_categories` — a
  `MapSet` of category slugs — that survives a LiveView remount.

  ## Why this exists at all

  `NucleusWeb.EnvironmentsHook` used to hold `:expanded_categories` purely
  as a socket assign, reset to `MapSet.new()` on every `on_mount`. Every
  sidebar environment link is `<.link navigate={...}>`
  (`NucleusWeb.Layouts.app/1`), and `Phoenix.LiveView.push_navigate/2`
  *always* fully remounts the destination LiveView — killing the old
  process and running `mount/3` and every `on_mount` hook again — even when
  the destination is the very same LiveView module with a different path
  param. There is no special-casing for "same module, different params."
  The practical effect: clicking any sidebar child link collapsed every
  open category, every time, regardless of which category the child came
  from — the whole point of "stay where you were" was structurally
  impossible with a plain assign.

  A `Plug.Session` cookie cannot fix this either: once a LiveView socket is
  connected, there is no `Plug.Conn` to write a new cookie value back
  through — the socket's session is fixed as of the request that
  established it. Persisting a *new* toggle would need a full HTTP
  round-trip (a redirect), which defeats the point of a `phx-click` toggle.

  So this module holds the state in the one place a live process *can*
  write to without an HTTP round-trip: a supervised, long-lived ETS table,
  keyed by a per-browser-session id (`NucleusWeb.Plugs.AssignScope` mints
  `nav_session_id`) — not by user identity. `AUTH_ENABLED=false`
  (`docs/adr/0005-deferred-authentication.md`) means every request
  currently resolves to the *same* dev `Nucleus.Scope`; keying by identity
  today would collapse every open tab and every dev session on the machine
  into one shared expand state. A random per-session id has no dependency
  on identity at all, so nothing here needs to change once real auth ships.

  ## Reads bypass this process, writes do not

  The table is `:protected` — readable by any process, writable only by
  its owner (this `GenServer`). `get/1` reads directly via `:ets.lookup/2`
  from the calling LiveView process, no message pass, because a read
  happens on *every* mount (every navigation) and must never queue behind
  anything. `toggle/2` goes through `GenServer.call/2` deliberately: two
  browser tabs of the same session toggling at nearly the same moment could
  otherwise both read the same starting `MapSet`, compute independently,
  and the second write would silently clobber the first (a lost update).
  Sending the *intent* ("toggle this slug for this session") rather than a
  precomputed result lets the single-threaded `handle_call` do the
  read-modify-write atomically — the one thing a fully `:public` table with
  callers writing precomputed values directly could not guarantee, at the
  cost of nothing on the read-heavy path.

  ## No eviction, deliberately, for now

  An entry is a `MapSet` of a handful of short strings — negligible memory
  even held indefinitely. There is currently no hook for "this session's
  cookie expired, remove its entry"; this is an accepted, conscious
  trade-off rather than an oversight, revisited only if this table's size
  is ever actually observed to matter.
  """

  use GenServer

  @table :sidebar_expanded_categories

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The expanded categories for `session_id`, or `MapSet.new()` if this
  session has never toggled anything.

  Reads directly from ETS — never goes through the `GenServer` process.
  """
  @spec get(String.t()) :: MapSet.t(String.t())
  def get(session_id) when is_binary(session_id) do
    case :ets.lookup(@table, session_id) do
      [{^session_id, expanded}] -> expanded
      [] -> MapSet.new()
    end
  end

  def get(_session_id), do: MapSet.new()

  @doc """
  Toggles `category_slug` for `session_id` and returns the resulting
  `MapSet` — present if it was absent, absent if it was present.

  Routed through the `GenServer` so the read-modify-write is atomic; see
  the moduledoc for why a precomputed write would not be safe here.
  """
  @spec toggle(String.t(), String.t()) :: MapSet.t(String.t())
  def toggle(session_id, category_slug) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:toggle, session_id, category_slug})
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:toggle, session_id, category_slug}, _from, state) do
    current = get(session_id)

    updated =
      if MapSet.member?(current, category_slug) do
        MapSet.delete(current, category_slug)
      else
        MapSet.put(current, category_slug)
      end

    :ets.insert(@table, {session_id, updated})

    {:reply, updated, state}
  end
end
