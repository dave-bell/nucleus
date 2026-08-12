defmodule Nucleus.Secrets.Store do
  @moduledoc """
  The boundary to the tenant's own AWS SSM Parameter Store.

  This is where secret material is actually read and written, in the tenant's
  own AWS account, reached by assuming a scoped cross-account role. It is the
  highest-risk surface in the application — see
  `docs/adr/0002-backend-adapter-boundaries.md`.

  Two implementations, selected per boundary by `SECRETS_BACKEND` — see
  `Nucleus.Backend`:

  | Mode | Module | |
  |---|---|---|
  | `real` | `Nucleus.Secrets.Store.Aws` | `aws` package against Parameter Store |
  | `local` | `Nucleus.Secrets.Store.Local` | `priv/backends/local_seed.json`, via `Nucleus.Backend.Seed` |

  ## Call through this module, not an implementation

  Every function here resolves the implementation on every call, through
  `Nucleus.Backend.impl_for/1`. Nothing outside this module should name `Aws`
  or `Local` directly.

  ## No `token` argument

  Unlike `Nucleus.TenantApi`, none of these callbacks take the signed-in
  user's access token. Parameter Store is reached with credentials Nucleus
  obtains for itself by assuming a role, not with the user's token — which is
  precisely why `SEC-A18` (server-side credentials expiring mid-session) is a
  distinct failure mode from the user's own session expiring.

  ## No delete operation

  Wiki [Secrets](https://github.com/dave-bell/nucleus/wiki/Secrets): "Secrets
  have no delete operation: once created, a secret can be viewed and updated,
  but not removed." This is a deliberate safety boundary, not an omission —
  do not add one.

  ## `create_secret/3` and `update_secret/3` are separate callbacks

  They have genuinely different contracts:

    * `create_secret/3` on an existing key returns
      `{:error, %Error{kind: :already_exists}}` (`SEC-A12`)
    * `update_secret/3` on a missing key returns
      `{:error, %Error{kind: :not_found}}`

  Collapsing them into one upsert would make `SEC-A12` unimplementable without
  a racy read-then-write.

  ## `list_environments/0` and `list_all_secrets/0`

  This boundary is deliberately decoupled from `Nucleus.TenantApi` (environment
  names here are arbitrary Parameter Store buckets, not validated against the
  tenant's API — see `Nucleus.Secrets.Path`), so nothing else tells the app
  what buckets exist in Parameter Store. `list_environments/0` backs discovery
  of which buckets exist at all; `list_all_secrets/0` backs a tenant-wide view
  across every bucket, including `shared`. `list_secrets/1` still backs the
  existing per-environment component, unchanged.
  """

  alias Nucleus.Backend
  alias Nucleus.Backend.Error
  alias Nucleus.Secrets.Secret
  alias Nucleus.Secrets.SecretLocation
  alias Nucleus.Secrets.SecretRef

  @boundary :secrets

  @doc """
  Every secret's metadata for `environment`, values never included (`SEC-A01`).

  Returns `{:ok, []}` for a valid-but-empty environment (`SEC-A14`), never an
  error.
  """
  @callback list_secrets(environment :: String.t()) ::
              {:ok, [SecretRef.t()]} | {:error, Error.t()}

  @doc """
  Reveals one secret's plaintext value (`SEC-A03`).

  `{:error, %Error{kind: :not_found}}` when `key` does not exist in
  `environment`.
  """
  @callback get_secret(environment :: String.t(), key :: String.t()) ::
              {:ok, Secret.t()} | {:error, Error.t()}

  @doc """
  Creates a new secret (`SEC-A09`).

  `{:error, %Error{kind: :already_exists}}` when `key` already exists in
  `environment` — never overwrites.
  """
  @callback create_secret(environment :: String.t(), key :: String.t(), value :: String.t()) ::
              {:ok, SecretRef.t()} | {:error, Error.t()}

  @doc """
  Updates an existing secret's value (`SEC-A06`).

  `{:error, %Error{kind: :not_found}}` when `key` does not exist in
  `environment` — never creates.
  """
  @callback update_secret(environment :: String.t(), key :: String.t(), value :: String.t()) ::
              {:ok, SecretRef.t()} | {:error, Error.t()}

  @doc """
  The path and ARN a secret would resolve to, without its value (`SEC-A02`).
  """
  @callback locate_secret(environment :: String.t(), key :: String.t()) ::
              {:ok, SecretLocation.t()} | {:error, Error.t()}

  @doc """
  Every bucket (environment name) that exists in Parameter Store at all.
  """
  @callback list_environments() :: {:ok, [String.t()]} | {:error, Error.t()}

  @doc """
  Every secret across every bucket, for the tenant-wide view.
  """
  @callback list_all_secrets() ::
              {:ok, [%{environment: String.t(), secret: SecretRef.t()}]} | {:error, Error.t()}

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
  Lists secret metadata for `environment` through the configured implementation.
  """
  @spec list_secrets(String.t()) :: {:ok, [SecretRef.t()]} | {:error, Error.t()}
  def list_secrets(environment) when is_binary(environment), do: impl().list_secrets(environment)

  @doc """
  Reveals `key`'s plaintext value in `environment`.
  """
  @spec get_secret(String.t(), String.t()) :: {:ok, Secret.t()} | {:error, Error.t()}
  def get_secret(environment, key) when is_binary(environment) and is_binary(key) do
    impl().get_secret(environment, key)
  end

  @doc """
  Creates `key` in `environment` with `value`. Fails if `key` already exists.
  """
  @spec create_secret(String.t(), String.t(), String.t()) ::
          {:ok, SecretRef.t()} | {:error, Error.t()}
  def create_secret(environment, key, value)
      when is_binary(environment) and is_binary(key) and is_binary(value) do
    impl().create_secret(environment, key, value)
  end

  @doc """
  Updates `key` in `environment` to `value`. Fails if `key` does not exist.
  """
  @spec update_secret(String.t(), String.t(), String.t()) ::
          {:ok, SecretRef.t()} | {:error, Error.t()}
  def update_secret(environment, key, value)
      when is_binary(environment) and is_binary(key) and is_binary(value) do
    impl().update_secret(environment, key, value)
  end

  @doc """
  The path and ARN `key` in `environment` would resolve to.
  """
  @spec locate_secret(String.t(), String.t()) :: {:ok, SecretLocation.t()} | {:error, Error.t()}
  def locate_secret(environment, key) when is_binary(environment) and is_binary(key) do
    impl().locate_secret(environment, key)
  end

  @doc """
  Every bucket that exists in Parameter Store.
  """
  @spec list_environments() :: {:ok, [String.t()]} | {:error, Error.t()}
  def list_environments, do: impl().list_environments()

  @doc """
  Every secret across every bucket.
  """
  @spec list_all_secrets() ::
          {:ok, [%{environment: String.t(), secret: SecretRef.t()}]} | {:error, Error.t()}
  def list_all_secrets, do: impl().list_all_secrets()

  @doc """
  Checks the configured implementation can reach Parameter Store.
  """
  @spec health_check() :: :ok | {:error, Error.t()}
  def health_check, do: impl().health_check()

  defp impl, do: Backend.impl_for(@boundary)
end
