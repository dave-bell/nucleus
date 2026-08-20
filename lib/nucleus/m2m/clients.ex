defmodule Nucleus.M2M.Clients do
  @moduledoc """
  The boundary to Cognito App Clients configured for the `client_credentials`
  OAuth flow — Nucleus's only supported way to create and rotate machine
  credentials for a tenant's own APIs.

  Two implementations, selected per boundary by `M2M_BACKEND` — see
  `Nucleus.Backend`:

  | Mode | Module | |
  |---|---|---|
  | `real` | `Nucleus.M2M.Clients.Cognito` | `aws` package against Cognito App Clients |
  | `local` | `Nucleus.M2M.Clients.Local` | `priv/backends/local_seed.json`, via `Nucleus.Backend.Seed` |

  ## Call through this module, not an implementation

  Every function here resolves the implementation on every call, through
  `Nucleus.Backend.impl_for/1`. Nothing outside this module should name
  `Cognito` or `Local` directly.

  ## No update callback and no delete callback

  Wiki [M2M-Clients](https://github.com/dave-bell/nucleus/wiki/M2M-Clients):
  clients "cannot be updated (beyond secret rotation) or deleted through this
  feature." `M2M-A15` is explicit that renaming, reconfiguring, and deleting
  are all unavailable — only secret rotation is offered. This is the same
  deliberate omission `Nucleus.Secrets.Store`'s moduledoc documents for
  deletion; do not add either callback here.

  ## `describe_client/1` assumes a pre-validated, in-scope client ID

  This callback applies **no tenant or deny-list filtering** of its own.
  Those checks — is this ID well-formed, does it belong to this tenant's
  namespace, is it on the reserved deny-list — are the caller's gate,
  deliberately above this boundary, because they depend on `TENANT_NAMESPACE`
  and `M2M_DENY_SUFFIXES`: application policy, not Cognito mechanics. A
  caller that skips its own gate and hands this an out-of-scope ID gets
  whatever Cognito itself says about that ID, not a `:not_found` this module
  manufactured on its behalf.

  ## No claim on client-name uniqueness

  Cognito does not require `ClientName` to be unique within a pool, so
  `create_client/2` always creates the client it is asked to — there is no
  duplicate-name rejection here, and none is planned
  (see the [decision](https://github.com/dave-bell/nucleus/issues/33#issuecomment-5350191153)
  removing `M2M-A09`). `client_id` is what actually identifies a client.
  """

  alias Nucleus.Backend
  alias Nucleus.Backend.Error
  alias Nucleus.M2M.Client
  alias Nucleus.M2M.ClientCredentials
  alias Nucleus.M2M.ClientDetail

  @boundary :m2m

  @min_token_validity_minutes 5
  @max_token_validity_minutes 60

  @doc """
  Every M2M client belonging to this tenant, unfiltered by tenant scope or
  deny-list (`M2M-A01`'s filtering is the caller's job — see the moduledoc).

  A per-client failure while filling in `created_date` degrades that one row
  (`created_date: nil`, `created_date_error: kind`) rather than failing the
  whole list — only a failure of the underlying list call itself does that.
  """
  @callback list_clients() :: {:ok, [Client.t()]} | {:error, Error.t()}

  @doc """
  One client's full detail, by `client_id` (`M2M-A03`).

  Assumes a pre-validated, in-tenant client ID — see the moduledoc.
  `{:error, %Error{kind: :not_found}}` when no such client exists.
  """
  @callback describe_client(client_id :: String.t()) ::
              {:ok, ClientDetail.t()} | {:error, Error.t()}

  @doc """
  Creates a new client-credentials app client (`M2M-A08`).

  `settings` carries `token_validity_minutes: pos_integer()` — a whole number
  of minutes from #{@min_token_validity_minutes} to #{@max_token_validity_minutes}
  inclusive (#{@min_token_validity_minutes} is Cognito's own documented floor
  for `AccessTokenValidity`, 300 seconds; #{@max_token_validity_minutes} is
  this feature's own ceiling). Outside that range, `{:error, %Error{kind:
  :invalid}}` — a structural guard both implementations enforce themselves,
  independent of M2M-S4's (#37) form validation.

  Always creates, even when a client of the same name already exists —
  Cognito does not enforce name uniqueness (see the moduledoc).
  """
  @callback create_client(client_name :: String.t(), settings :: keyword()) ::
              {:ok, ClientCredentials.t()} | {:error, Error.t()}

  @doc """
  Issues a new secret for `client_id`, without changing the client ID itself
  (`M2M-A11`). The old secret remains valid until the next rotation.

  `{:error, %Error{kind: :not_found}}` when no such client exists.
  """
  @callback rotate_secret(client_id :: String.t()) ::
              {:ok, ClientCredentials.t()} | {:error, Error.t()}

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
  The valid range for `create_client/2`'s `token_validity_minutes`, inclusive.
  """
  @spec token_validity_range() :: Range.t()
  def token_validity_range, do: @min_token_validity_minutes..@max_token_validity_minutes

  @doc """
  Lists every M2M client through the configured implementation.
  """
  @spec list_clients() :: {:ok, [Client.t()]} | {:error, Error.t()}
  def list_clients, do: impl().list_clients()

  @doc """
  Describes one client by `client_id` through the configured implementation.
  """
  @spec describe_client(String.t()) :: {:ok, ClientDetail.t()} | {:error, Error.t()}
  def describe_client(client_id) when is_binary(client_id), do: impl().describe_client(client_id)

  @doc """
  Creates a client through the configured implementation.
  """
  @spec create_client(String.t(), keyword()) ::
          {:ok, ClientCredentials.t()} | {:error, Error.t()}
  def create_client(client_name, settings) when is_binary(client_name) and is_list(settings) do
    impl().create_client(client_name, settings)
  end

  @doc """
  Rotates `client_id`'s secret through the configured implementation.
  """
  @spec rotate_secret(String.t()) :: {:ok, ClientCredentials.t()} | {:error, Error.t()}
  def rotate_secret(client_id) when is_binary(client_id), do: impl().rotate_secret(client_id)

  @doc """
  Checks the configured implementation can reach Cognito.
  """
  @spec health_check() :: :ok | {:error, Error.t()}
  def health_check, do: impl().health_check()

  defp impl, do: Backend.impl_for(@boundary)
end
