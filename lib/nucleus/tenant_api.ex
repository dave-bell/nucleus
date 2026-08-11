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

  `list_environments/1` and `health_check/0` here resolve the implementation on
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

  ## On the token argument

  `list_environments/1` takes the signed-in user's access token, so the tenant's
  API applies *their* permissions rather than a service account's.

  Authentication is deferred to EN-6, so callers pass `nil` today and the HTTP
  implementation sends no `Authorization` header. The parameter exists now
  regardless: adding it later would touch every call site, and the alternative —
  inventing a service-account token to fill the gap — would build in exactly the
  permission escalation the passthrough model exists to avoid.
  """

  alias Nucleus.Backend
  alias Nucleus.Backend.Error
  alias Nucleus.TenantApi.Environment

  @boundary :tenant_api

  @doc """
  Every environment the tenant's API reports, archived ones included.
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
  Lists environments through the configured implementation.

  See the module documentation on why `token` may be `nil`, and why archived
  environments are included.
  """
  @spec list_environments(String.t() | nil) :: {:ok, [Environment.t()]} | {:error, Error.t()}
  def list_environments(token) when is_binary(token) or is_nil(token) do
    impl().list_environments(token)
  end

  @doc """
  Checks the configured implementation can reach the tenant's API.
  """
  @spec health_check() :: :ok | {:error, Error.t()}
  def health_check, do: impl().health_check()

  defp impl, do: Backend.impl_for(@boundary)
end
