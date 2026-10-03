defmodule Nucleus.TenantApi.ServiceToken do
  @moduledoc """
  Nucleus's own access token for the tenant's API — a service credential, not the
  signed-in user's.

  Nucleus keeps no user token after sign-in (ADR-0038). The tenant API is reached
  with a token Nucleus obtains for itself through the Cognito client-credentials
  grant, and this module is where that token is held. Decision and rationale:
  `docs/adr/0039-tenant-api-service-credential.md`.

  ## A cache in front of a driver

  This process knows nothing about Cognito. It caches whatever token its driver
  returns and asks the driver for a new one on a miss. The driver is the
  `:service_token` boundary (`SERVICE_TOKEN_BACKEND`), so dev and test run the
  same cache code path against `Nucleus.TenantApi.ServiceToken.Local`, which
  returns a canned token, and production runs it against
  `Nucleus.TenantApi.ServiceToken.Cognito`.

  | Mode | Module | |
  |---|---|---|
  | `real` | `Nucleus.TenantApi.ServiceToken.Cognito` | client-credentials grant against Cognito |
  | `local` | `Nucleus.TenantApi.ServiceToken.Local` | a canned token |

  ## Caching

  - **Until `expires_in` minus 60 seconds.** A token is never handed out in the
    last minute of its life, so a call that starts with a cached token does not
    have it expire underneath it.
  - **One fetch at a time.** Callers that arrive while a fetch is in flight wait
    for that fetch rather than starting their own.
  - **Errors are never cached.** A failed fetch answers every caller waiting on
    it, and the next call tries again.
  - **The fetch runs outside this process** (`Nucleus.TaskSupervisor`), so a slow
    or crashing driver cannot wedge or kill the cache. A crashed fetch is
    `:unavailable`.

  ## Invalidation

  `invalidate/2` takes the token that was *rejected* and drops the cache only if
  it still holds that token. Two callers that both get a 401 on the same old
  token therefore cannot discard the fresh token one of them just fetched.
  `Nucleus.TenantApi` calls it when the tenant API answers `:auth_expired`.
  `clear/1` drops the cache unconditionally.

  Nothing here retries. The single automatic retry after a rejected token is
  SEC-S7's, at the context layer; invalidation is what makes that retry fetch a
  fresh token instead of resending the rejected one.

  ## Never logged

  The token, and the client secret behind it, are never logged, never put in an
  error's `details`, and never rendered. A token held here is a credential for
  the whole tenant API.
  """

  use GenServer

  alias Nucleus.Backend
  alias Nucleus.Backend.Error

  @boundary :service_token
  @skew_seconds 60
  @call_timeout_ms 25_000

  @typedoc "A fetched token and how long the issuer says it is good for."
  @type grant :: %{token: String.t(), expires_in: pos_integer()}

  @doc """
  Asks the issuer for a new token. Called by the cache on a miss, never by
  application code.
  """
  @callback request_token() :: {:ok, grant()} | {:error, Error.t()}

  @doc """
  Whether this boundary can reach its issuer.
  """
  @callback health_check() :: :ok | {:error, Error.t()}

  @doc """
  The boundary name, for `Nucleus.Backend` and error construction.
  """
  @spec boundary() :: atom()
  def boundary, do: @boundary

  @doc """
  Starts the cache.

  Options: `:name` (default `#{inspect(__MODULE__)}`), `:driver` (default: the
  module configured for the `:service_token` boundary, resolved on each fetch),
  and `:clock` — a zero-arity function returning monotonic milliseconds, so tests
  can move time without sleeping.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The current token, fetching one if none is cached.

  Returns the driver's error unchanged when a fetch fails. A cache that cannot be
  reached at all is `:unavailable`, never an exit in the caller.
  """
  @spec fetch(GenServer.server()) :: {:ok, String.t()} | {:error, Error.t()}
  def fetch(server \\ __MODULE__) do
    GenServer.call(server, :fetch, @call_timeout_ms)
  catch
    :exit, _reason ->
      {:error, Error.new(:unavailable, @boundary, "the service token cache is unavailable", %{})}
  end

  @doc """
  Drops the cached token if it is still `rejected_token`.

  Returns `:ok` either way. A different token in the cache means someone already
  replaced the rejected one, and is left alone.
  """
  @spec invalidate(GenServer.server(), String.t()) :: :ok
  def invalidate(server \\ __MODULE__, rejected_token) when is_binary(rejected_token) do
    GenServer.cast(server, {:invalidate, rejected_token})
  end

  @doc """
  Drops the cached token unconditionally.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server \\ __MODULE__), do: GenServer.call(server, :clear)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       driver: Keyword.get(opts, :driver),
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       cached: nil,
       inflight: nil
     }}
  end

  @impl GenServer
  def handle_call(:fetch, from, state) do
    case cached_token(state) do
      {:ok, token} ->
        {:reply, {:ok, token}, state}

      :miss ->
        {:noreply, join_or_start_fetch(from, state)}
    end
  end

  def handle_call(:clear, _from, state), do: {:reply, :ok, %{state | cached: nil}}

  @impl GenServer
  def handle_cast({:invalidate, rejected}, %{cached: {rejected, _expires_at}} = state) do
    {:noreply, %{state | cached: nil}}
  end

  def handle_cast({:invalidate, _other}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({ref, result}, %{inflight: %{ref: ref, waiters: waiters}} = state) do
    Process.demonitor(ref, [:flush])

    {reply, cached} = settle(result, state)
    Enum.each(waiters, &GenServer.reply(&1, reply))

    {:noreply, %{state | inflight: nil, cached: cached}}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{inflight: %{ref: ref} = flight} = state
      ) do
    error = Error.new(:unavailable, @boundary, "the token request crashed", %{})
    Enum.each(flight.waiters, &GenServer.reply(&1, {:error, error}))

    {:noreply, %{state | inflight: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp cached_token(%{cached: {token, expires_at}, clock: clock}) do
    if clock.() < expires_at, do: {:ok, token}, else: :miss
  end

  defp cached_token(_state), do: :miss

  defp join_or_start_fetch(from, %{inflight: %{waiters: waiters} = flight} = state) do
    %{state | inflight: %{flight | waiters: [from | waiters]}}
  end

  defp join_or_start_fetch(from, state) do
    task =
      Task.Supervisor.async_nolink(Nucleus.TaskSupervisor, fn -> request_token(state.driver) end)

    %{state | inflight: %{ref: task.ref, waiters: [from]}}
  end

  defp request_token(nil), do: Backend.impl_for(@boundary).request_token()
  defp request_token(driver), do: driver.request_token()

  # Only a well-formed grant is cached and handed out. Anything else — including
  # a driver that breaks its contract — is an error and is not cached.
  defp settle({:ok, %{token: token, expires_in: expires_in}}, state)
       when is_binary(token) and token != "" and is_integer(expires_in) and expires_in > 0 do
    ttl_ms = max(expires_in - @skew_seconds, 0) * 1_000
    {{:ok, token}, {token, state.clock.() + ttl_ms}}
  end

  defp settle({:error, %Error{} = error}, _state), do: {{:error, error}, nil}

  defp settle(_malformed, _state) do
    error = Error.new(:unavailable, @boundary, "the token issuer returned an unusable grant", %{})
    {{:error, error}, nil}
  end
end
