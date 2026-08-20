defmodule Nucleus.Backend do
  @moduledoc """
  Selection and registry for the swappable backend boundaries.

  Nucleus holds no data of its own; every value it shows is read live from an
  external system. Each of those systems sits behind a *boundary* — an Elixir
  behaviour with a `real` implementation that talks to the live system and a
  `local` implementation that serves in-memory data. Which one runs is
  configuration, decided per boundary.

  ## Boundaries

  | Boundary | External system | Real impl | Local impl |
  |---|---|---|---|
  | `:secrets` | AWS SSM Parameter Store, in the tenant's account | `Nucleus.Secrets.Store.Aws` | `Nucleus.Secrets.Store.Local` |
  | `:tenant_api` | Tenant backing API (authoritative environment list) | `Nucleus.TenantApi.Http` | `Nucleus.TenantApi.Local` |
  | `:m2m` | Cognito App Clients, in this tenant's user pool | `Nucleus.M2M.Clients.Cognito` | `Nucleus.M2M.Clients.Local` |

  The behaviours and both implementations are delivered by EN-3 (`:tenant_api`),
  EN-4 (`:secrets`), and EN-10 (`:m2m`). This module is the shared scaffolding
  they plug into, so the module names above are registered here before the
  modules exist.

  Authentication is deliberately absent. There is no `:auth` boundary and no
  `AUTH_BACKEND` — auth is the actual security boundary and is never swappable.

  ## Selection

      config :nucleus, :backends, secrets: Nucleus.Secrets.Store.Aws, tenant_api: Nucleus.TenantApi.Http, m2m: Nucleus.M2M.Clients.Cognito

  `config/dev.exs` and `config/test.exs` override all three to the local
  implementations, so a fresh clone runs and its tests pass with no
  credentials at all. `config/runtime.exs` allows a per-boundary override
  through `SECRETS_BACKEND`, `TENANT_API_BACKEND`, and `M2M_BACKEND`, each
  `"real"` (the default) or `"local"`.

  Selection is per boundary rather than one global switch because the pain it
  solves is per boundary: Parameter Store access needs a Terraform-provisioned
  cross-account IAM role, and a developer working only on environment listing
  should not have to obtain one.

  ## Required callback on every boundary behaviour

      @callback health_check() :: :ok | {:error, Nucleus.Backend.Error.t()}

  Readiness must be answerable *through* the boundary. The prototype's readiness
  check reached into a plugin's private client attribute, which only went
  unnoticed because there was a single implementation of that plugin.

  ## Errors

  Callbacks return `{:error, Nucleus.Backend.Error.t()}` — never a
  backend-specific exception, and never a raised one. See `Nucleus.Backend.Error`.
  """

  require Logger

  @impls %{
    secrets: %{real: Nucleus.Secrets.Store.Aws, local: Nucleus.Secrets.Store.Local},
    tenant_api: %{real: Nucleus.TenantApi.Http, local: Nucleus.TenantApi.Local},
    m2m: %{real: Nucleus.M2M.Clients.Cognito, local: Nucleus.M2M.Clients.Local}
  }

  @boundaries Enum.sort(Map.keys(@impls))

  @type boundary :: :secrets | :tenant_api | :m2m
  @type mode :: :real | :local

  @doc """
  Every known boundary.

      iex> Nucleus.Backend.boundaries()
      [:m2m, :secrets, :tenant_api]
  """
  @spec boundaries() :: [boundary()]
  def boundaries, do: @boundaries

  @doc """
  The module implementing `boundary`, from application configuration.

  Resolved at call time rather than compile time so that `config/runtime.exs`
  and test overrides both take effect. Raises rather than returning an error
  tuple: an unconfigured boundary is a deployment mistake, not a runtime
  condition a LiveView could sensibly render.
  """
  @spec impl_for(boundary()) :: module()
  def impl_for(boundary) when is_atom(boundary) do
    if boundary not in @boundaries do
      raise ArgumentError, """
      unknown backend boundary: #{inspect(boundary)}

      Known boundaries: #{inspect(@boundaries)}.
      Add the boundary to @impls in Nucleus.Backend if it is a new one.
      """
    end

    module = Application.get_env(:nucleus, :backends, [])[boundary]

    cond do
      is_nil(module) ->
        raise """
        no backend configured for boundary #{inspect(boundary)}

        Add it to config/config.exs:

            config :nucleus, :backends, #{boundary}: #{inspect(impl_for_mode!(boundary, :real))}

        Or select the local implementation with #{env_var(boundary)}=local.
        """

      not Code.ensure_loaded?(module) ->
        raise """
        backend for boundary #{inspect(boundary)} is configured as #{inspect(module)}, \
        which is not a loaded module

        Either the module name is misspelled in config, or it has not been \
        written yet. The implementations for this boundary are \
        #{inspect(impl_for_mode!(boundary, :real))} (real) and \
        #{inspect(impl_for_mode!(boundary, :local))} (local).
        """

      true ->
        module
    end
  end

  @doc """
  The registered implementation of `boundary` for `mode`.

  Accepts a string mode so `config/runtime.exs` can hand an environment variable
  straight in. This is the single source of truth for which module means "real"
  and which means "local" — the boot warning and the runtime env var override
  both read it.

      iex> Nucleus.Backend.impl_for_mode!(:secrets, "local")
      Nucleus.Secrets.Store.Local
  """
  @spec impl_for_mode!(boundary(), mode() | String.t()) :: module()
  def impl_for_mode!(boundary, mode) when is_binary(mode) do
    case mode do
      "real" -> impl_for_mode!(boundary, :real)
      "local" -> impl_for_mode!(boundary, :local)
      other -> raise ArgumentError, bad_mode_message(boundary, other)
    end
  end

  def impl_for_mode!(boundary, mode) when mode in [:real, :local] do
    case @impls[boundary] do
      nil -> raise ArgumentError, "unknown backend boundary: #{inspect(boundary)}"
      impls -> impls[mode]
    end
  end

  def impl_for_mode!(boundary, mode), do: raise(ArgumentError, bad_mode_message(boundary, mode))

  @doc """
  The environment variable that overrides `boundary`'s implementation.

      iex> Nucleus.Backend.env_var(:tenant_api)
      "TENANT_API_BACKEND"
  """
  @spec env_var(boundary()) :: String.t()
  def env_var(boundary) when boundary in @boundaries do
    boundary |> Atom.to_string() |> String.upcase() |> Kernel.<>("_BACKEND")
  end

  @doc """
  Boundaries currently configured to their local implementation.
  """
  @spec local_boundaries() :: [boundary()]
  def local_boundaries do
    configured = Application.get_env(:nucleus, :backends, [])

    Enum.filter(@boundaries, fn boundary ->
      configured[boundary] == impl_for_mode!(boundary, :local)
    end)
  end

  @doc """
  Logs one prominent warning if any boundary is serving local data.

  Called on boot. Local implementations are shipped in the release rather than
  excluded from it — keeping the build and the package list in sync is its own
  failure mode, and auth is never swappable, so a misconfigured
  `*_BACKEND=local` in production serves wrong data to already-authorised users
  rather than bypassing authorisation. This warning is the cheap, loud signal
  chosen in place of that packaging complexity.
  """
  @spec warn_on_local_backends() :: :ok
  def warn_on_local_backends do
    case local_boundaries() do
      [] ->
        :ok

      boundaries ->
        Logger.warning("""
        LOCAL BACKENDS ACTIVE — the following boundaries are serving in-memory data, not the real system:
        #{Enum.map_join(boundaries, "\n", &describe_local/1)}

        Nothing displayed for these boundaries reflects the tenant's real state.
        """)

        :ok
    end
  end

  defp describe_local(boundary) do
    "  * #{boundary} -> #{inspect(impl_for_mode!(boundary, :local))} (#{env_var(boundary)}=local)"
  end

  defp bad_mode_message(boundary, mode) do
    """
    invalid backend mode #{inspect(mode)} for boundary #{inspect(boundary)}

    #{env_var_hint(boundary)} must be "real" or "local".
    """
  end

  defp env_var_hint(boundary) when boundary in @boundaries, do: env_var(boundary)
  defp env_var_hint(_boundary), do: "The backend mode"
end
