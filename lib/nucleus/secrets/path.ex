defmodule Nucleus.Secrets.Path do
  @moduledoc """
  The one place a Parameter Store path is built.

  Confirmed pattern (`EN-4` Decision 1):

      /{cluster}/deployments/{deployment}/faas/functions/{environment}/{key}

  `{cluster}` and `{deployment}` are deploy-time configuration
  (`CLUSTER_NAME`/`DEPLOYMENT_NAME`, read once at boot into
  `config :nucleus, #{inspect(__MODULE__)}`), never derived from any API call.
  `{environment}` is an arbitrary bucket that exists directly in Parameter
  Store — a real Labbit environment short name, or the literal `shared` — and
  is **not** validated against, or sourced from, `Nucleus.TenantApi`. That
  decoupling is deliberate: this boundary is pure CRUD over whatever exists
  under the cluster/deployment prefix, not a mirror of the tenant's
  environment list. `faas/functions` is a fixed literal for this ticket; other
  resource kinds under `/{cluster}/deployments/{deployment}/` are future
  scope.

  ## Every path in the system comes from here

  The list prefix, `get`, `put`, and the `resource` field on every audit event
  must all be built by `build/2`. Grep-ability is the point:
  `rg 'Secrets.Path.build'` finds every construction site.

  ## This function assumes pre-validated input

  `build/2` does not sanitise `environment` or `key`. Rejecting `..`, `/`,
  `\\` and null bytes is `SEC-S1`/`SEC-S6`'s job, enforced *before* this is
  called. Do not mistake this for a sanitiser — it concatenates its arguments
  verbatim.
  """

  @doc """
  Builds the Parameter Store path for `environment`/`key`.

  Assumes both arguments are already validated (see the module doc). Reads
  `CLUSTER_NAME`/`DEPLOYMENT_NAME` from config rather than taking a namespace
  argument — every caller gets the same cluster/deployment prefix, there is
  nothing per-call to vary.

      iex> Application.put_env(:nucleus, Nucleus.Secrets.Path, cluster_name: "acme", deployment_name: "main")
      iex> Nucleus.Secrets.Path.build("prod", "db-password")
      "/acme/deployments/main/faas/functions/prod/db-password"
  """
  @spec build(String.t(), String.t()) :: String.t()
  def build(environment, key) when is_binary(environment) and is_binary(key) do
    "/#{cluster_name()}/deployments/#{deployment_name()}/faas/functions/#{environment}/#{key}"
  end

  @doc """
  The `faas/functions` prefix for `environment`, with no trailing key.

  Used by the AWS implementation's `list_secrets/1` as the `GetParametersByPath`
  `Path`, and by `list_environments/0`/`list_all_secrets/0` for the
  bucket-spanning prefix one level up.
  """
  @spec prefix(String.t() | nil) :: String.t()
  def prefix(nil) do
    "/#{cluster_name()}/deployments/#{deployment_name()}/faas/functions"
  end

  def prefix(environment) when is_binary(environment) do
    prefix(nil) <> "/" <> environment
  end

  @doc """
  The deploy-time cluster name, from `CLUSTER_NAME`.

  Raises when unconfigured — a missing cluster name is a deployment mistake
  (see `config/runtime.exs`), never a runtime condition a caller could
  sensibly render.
  """
  @spec cluster_name() :: String.t()
  def cluster_name, do: fetch!(:cluster_name, "CLUSTER_NAME")

  @doc """
  The deploy-time deployment name, from `DEPLOYMENT_NAME`.
  """
  @spec deployment_name() :: String.t()
  def deployment_name, do: fetch!(:deployment_name, "DEPLOYMENT_NAME")

  @doc """
  Whether `CLUSTER_NAME` and `DEPLOYMENT_NAME` are both present.

  For a caller that wants a missing value to surface as a tagged
  `{:error, %Nucleus.Backend.Error{kind: :not_configured}}` rather than the
  raise `build/2`, `cluster_name/0` and `deployment_name/0` give — real
  deployments validate this at boot (`config/runtime.exs`'s unconditional
  requirement in production), so the raise there reflects a deployment
  mistake, not a runtime condition. `Nucleus.Secrets.Store.Aws` checks this
  first so a misconfigured deployment fails as `:not_configured`, matching
  its documented error mapping, rather than crashing mid-request.
  """
  @spec configured?() :: boolean()
  def configured? do
    present?(:cluster_name) and present?(:deployment_name)
  end

  defp present?(key) do
    case Application.get_env(:nucleus, __MODULE__, []) |> Keyword.get(key) do
      value when is_binary(value) and value != "" -> true
      _absent_or_blank -> false
    end
  end

  defp fetch!(key, env_var) do
    case Application.get_env(:nucleus, __MODULE__, []) |> Keyword.get(key) do
      value when is_binary(value) and value != "" ->
        value

      _absent_or_blank ->
        raise """
        #{env_var} is missing or blank.

        Set it in config/runtime.exs (required unconditionally in production),
        or add a hardcoded default to config/dev.exs / config/test.exs.
        """
    end
  end
end
