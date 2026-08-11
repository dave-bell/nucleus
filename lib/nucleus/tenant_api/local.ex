defmodule Nucleus.TenantApi.Local do
  @moduledoc """
  The tenant API served from `priv/backends/local_seed.json`.

  This is what makes a fresh clone run: environment listing needs no credentials,
  no network and no tenant. It is a real implementation of the behaviour, not a
  test double — the same module serves `mix phx.server` in development and the
  test suite, so there is nothing to drift.

  Reads the `tenant_api` section of the shared seed through
  `Nucleus.Backend.Seed`, which parses the file once at start-up. The other
  sections belong to other boundaries and are ignored here.

  ## The fixtures are deliberate

  Downstream tickets need edge cases to build against, and inventing them per
  ticket is how two tickets end up disagreeing about what "no description" looks
  like:

  | Environment | Exercises |
  |---|---|
  | `prod` | multiple categories, has a description |
  | `staging` | a single category |
  | `dev` | **no categories** — `ENV-A02`/`NAV-A04` grouping fallback |
  | `sandbox` | **no description** — `ENV-A02` omission, must surface as `nil` |
  | `legacy-qa` | **archived** — `ENV-A06` reachable but hidden |

  ## Faults come first

  Every callback calls `Nucleus.Backend.Faults.maybe_fault/1` before doing
  anything. Data that always succeeds instantly never exercises a spinner or an
  error branch, and `SEC-S1`'s fail-closed behaviour is not testable without a
  way to make this implementation fail on demand (`LOCAL_FORCE_ERROR=unavailable`).
  """

  @behaviour Nucleus.TenantApi

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Faults
  alias Nucleus.Backend.Seed
  alias Nucleus.TenantApi
  alias Nucleus.TenantApi.Environment

  @impl Nucleus.TenantApi
  def list_environments(_token) do
    with :ok <- Faults.maybe_fault(TenantApi.boundary()) do
      environments()
    end
  end

  @impl Nucleus.TenantApi
  def health_check do
    with :ok <- Faults.maybe_fault(TenantApi.boundary()),
         {:ok, _environments} <- environments() do
      :ok
    end
  end

  defp environments do
    case Seed.read(TenantApi.boundary()) do
      %{"environments" => raw} when is_list(raw) ->
        decode(raw)

      nil ->
        {:error,
         error(
           :not_configured,
           ~s(the backend seed has no "tenant_api" section),
           %{seed_path: Seed.default_path()}
         )}

      other ->
        {:error,
         error(
           :not_configured,
           ~s(the seed's "tenant_api" section has no "environments" list),
           %{section: inspect(other)}
         )}
    end
  end

  defp decode(raw) do
    case Environment.from_api_list(raw) do
      {:ok, environments} ->
        {:ok, environments}

      {:error, reason} ->
        # A bad seed is a bad checked-in file, not an unreachable backend, so it
        # reads as `:not_configured` here where the same payload from a real API
        # would be `:unavailable`.
        {:error,
         error(:not_configured, "the seeded environment list is malformed", %{reason: reason})}
    end
  end

  defp error(kind, message, details) do
    Error.new(kind, TenantApi.boundary(), message, details)
  end
end
