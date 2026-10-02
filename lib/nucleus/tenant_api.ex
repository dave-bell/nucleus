defmodule Nucleus.TenantApi do
  @moduledoc """
  The boundary to the tenant's own backing API — the authority on environments.

  Nucleus is **not** authoritative for environments. The tenant's API is, and
  `SEC-A15`–`SEC-A17` require an environment name be validated against it
  *before* any Parameter Store path is built, with the request rejected outright
  when validation is unavailable. This boundary supplies the list that
  validation reads; the validation ladder itself is SEC-S1.

  Two implementations, selected per boundary by `TENANT_API_BACKEND` — see
  `Nucleus.Backend`:

  | Mode | Module | |
  |---|---|---|
  | `real` | `Nucleus.TenantApi.Http` | `Req` against the tenant's API |
  | `local` | `Nucleus.TenantApi.Local` | `priv/backends/local_seed.json` |

  ## Call through this module, not an implementation

  `list_environments/0` and `health_check/0` here resolve the implementation on
  every call. Nothing outside this module should name `Http` or `Local` — that
  is the coupling `Nucleus.Backend` exists to prevent, and resolving per call is
  what lets `config/runtime.exs` and a test override both take effect.

  ## Archived environments are returned

  Every environment comes back, archived ones included. `ENV-A06` requires an
  archived environment stay reachable by direct URL and usable for secrets
  management, while `NAV-A04` requires it be hidden from the sidebar. Those are
  different answers to different questions, so filtering belongs to the caller
  that knows which question it is asking. An adapter that dropped them would
  make `ENV-A06` unimplementable.

  ## The credential is Nucleus's own

  Callers pass nothing auth-related. Nucleus keeps no user token after sign-in
  (ADR-0038), so the tenant's API is reached with a service credential: a Cognito
  M2M access token Nucleus obtains for itself
  (`docs/adr/0039-tenant-api-service-credential.md`). It follows that the tenant
  API sees calls as coming from the Nucleus service, not from the signed-in user.

  **This module is where the token is fetched.** `list_environments/0` asks
  `Nucleus.TenantApi.ServiceToken` for one and hands it down as the
  implementation's `token` argument. The implementations still take it:
  `Http` sends it as `Authorization: Bearer`, `Local` ignores it, and a test can
  pass any value and stub the request. Dev and test fetch a token the same way
  production does — the `:service_token` boundary has a local driver that returns
  a canned one — so this code path has no mode check.

  - A token that cannot be fetched is returned as that error, and **no request is
    made** to the tenant API.
  - A tenant API `:auth_expired` (a 401 or 403) means the token in use was
    rejected. The cached token is invalidated, so the next call fetches a fresh
    one, and the error is returned unchanged. This module does not retry: the
    single automatic retry is SEC-S7's, at the context layer, and invalidation is
    what lets that retry succeed.

  `health_check/0` takes no token and sends none: it asks reachability only.
  """

  alias Nucleus.Backend
  alias Nucleus.Backend.Error
  alias Nucleus.TenantApi.Environment
  alias Nucleus.TenantApi.ServiceToken

  @boundary :tenant_api

  @doc """
  Every environment the tenant's API reports, archived ones included.

  `token` is the service credential `list_environments/0` fetched. An
  implementation that has no use for one ignores it.
  """
  @callback list_environments(token :: String.t() | nil) ::
              {:ok, [Environment.t()]} | {:error, Error.t()}

  @doc """
  Whether this boundary can reach the system behind it.
  """
  @callback health_check() :: :ok | {:error, Error.t()}

  @doc """
  The boundary name, for `Nucleus.Backend` and error construction.
  """
  @spec boundary() :: atom()
  def boundary, do: @boundary

  @doc """
  Lists environments through the configured implementation, using Nucleus's
  service credential.

  See the module documentation on the credential, and on why archived
  environments are included.
  """
  @spec list_environments() :: {:ok, [Environment.t()]} | {:error, Error.t()}
  def list_environments do
    with {:ok, token} <- ServiceToken.fetch() do
      case impl().list_environments(token) do
        {:error, %Error{kind: :auth_expired}} = rejected ->
          ServiceToken.invalidate(token)
          rejected

        result ->
          result
      end
    end
  end

  @doc """
  Checks the configured implementation can reach the tenant's API.
  """
  @spec health_check() :: :ok | {:error, Error.t()}
  def health_check, do: impl().health_check()

  defp impl, do: Backend.impl_for(@boundary)
end
