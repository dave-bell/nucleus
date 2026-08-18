defmodule Nucleus.Secrets do
  @moduledoc """
  The public context module `NucleusWeb.SecretsLive` talks to.

  Store access always goes through here so the environment gate cannot be
  bypassed — nothing outside this module should call `Nucleus.Secrets.Store`
  directly for a request that originated from a caller-supplied environment
  name.

  ## One call, not a combined result (`SEC-S2` decision 1)

  `list/2` gates internally via `Nucleus.Environments.fetch/2` and discards
  the resulting `%Nucleus.TenantApi.Environment{}` — the environment response
  is never merged with the secrets response, because the two backend
  boundaries stay separate (`:tenant_api` vs `:secrets`, see
  `Nucleus.Backend.Error.boundary`). The gate is load-bearing, not merely
  defensive: `Nucleus.Secrets.Store.Local.list_secrets/1` does
  `Map.get(buckets, environment, %{})`, so a nonexistent environment returns
  `{:ok, []}` — indistinguishable from a seeded empty environment
  (`SEC-A14`). `GetParametersByPath` behaves the same way against a path with
  nothing under it. Without this gate, `/environments/nope/secrets` would
  render `SEC-A14`'s "no secrets found" plus a create button for an
  environment that does not exist.

  Callers distinguish the two boundaries' `:unavailable` errors by matching
  on `error.boundary`, not just `error.kind` — both arrive with
  `kind: :unavailable`.
  """

  alias Nucleus.Backend.Error
  alias Nucleus.Environments
  alias Nucleus.Scope
  alias Nucleus.Secrets.SecretRef
  alias Nucleus.Secrets.Store

  @doc """
  Every secret's metadata for `environment`, re-validating the environment
  through `scope` before reaching the store.

  Values are never fetched, merged, or prefetched here — `SecretRef` has no
  `value` field at all (`SEC-A01`), and this function does not call
  `Store.get_secret/2`.

  Results are sorted by key, ascending, case-insensitive with the raw key as
  a tiebreak: `Enum.sort_by(refs, &{String.downcase(&1.key), &1.key})`. Keys
  are unique within an environment, so nothing can tie on both terms — the
  tiebreak makes the order total, not merely case-folded, so `API_KEY` and
  `api_key` (which collide under `String.downcase/1` alone) still sort
  deterministically instead of inheriting the store's iteration order.
  Neither `Store.Local` (a JSON-decoded map, whose iteration order is not
  insertion order past 32 keys) nor `Store.Aws` (`GetParametersByPath`
  pagination, unordered across pages) guarantees a stable order on its own —
  sorting belongs here, not in the template, so the UI and the tests are not
  flaky.

  Emits no audit event: the audit catalogue
  (`Nucleus.Audit.Event.events/0`) has no `secret_listed` entry. Listing
  exposes no values, so there is nothing sensitive to attribute — unlike
  Data Export's `nomad_vars_listed`, this is a deliberate omission, not an
  oversight.
  """
  @spec list(environment :: String.t(), scope :: Scope.t()) ::
          {:ok, [SecretRef.t()]} | {:error, Error.t()}
  def list(environment, %Scope{token: token}) when is_binary(environment) do
    with {:ok, _environment} <- Environments.fetch(environment, token),
         {:ok, refs} <- Store.list_secrets(environment) do
      {:ok, sort(refs)}
    end
  end

  defp sort(refs) do
    Enum.sort_by(refs, &{String.downcase(&1.key), &1.key})
  end
end
