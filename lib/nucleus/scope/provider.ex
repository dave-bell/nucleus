defmodule Nucleus.Scope.Provider do
  @moduledoc """
  Behaviour for building a `Nucleus.Scope` — the seam between "how identity is
  established" and everything downstream that only ever reads a `Scope`.

  Two implementations exist for the whole of EN-6:

  | Module | Role |
  |---|---|
  | `Nucleus.Scope.Provider.Disabled` | Default. Never fails; returns a scope built from a single configured dev identity. |
  | `Nucleus.Scope.Provider.Cognito` | A stub. Raises unconditionally — real authentication does not exist yet. |

  `configured/0` resolves which one is active from
  `config :nucleus, Nucleus.Scope, provider: ...`, set by `AUTH_ENABLED` in
  `config/runtime.exs`. There is deliberately no `AUTH_BACKEND`-style
  per-environment fallback logic here beyond that one switch — see
  `docs/adr/0005-deferred-authentication.md`.
  """

  alias Nucleus.Scope

  @doc """
  Builds a scope from `context` — whatever the caller has available (a
  captured `source_ip`, and eventually request headers or connect info a real
  provider would need).

  `Nucleus.Scope.Provider.Disabled` never returns `{:error, _}`.
  `Nucleus.Scope.Provider.Cognito` never returns at all — it raises.
  """
  @callback build(context :: map()) :: {:ok, Scope.t()} | {:error, term()}

  @doc """
  The provider module selected by application configuration.

  Defaults to `Nucleus.Scope.Provider.Disabled` so a fresh clone boots with
  auth disabled and no configuration at all.
  """
  @spec configured() :: module()
  def configured do
    Application.get_env(:nucleus, Scope, [])
    |> Keyword.get(:provider, Nucleus.Scope.Provider.Disabled)
  end

  @doc """
  Builds a scope through the configured provider.

  Raises whenever `configured/0` is `Nucleus.Scope.Provider.Cognito` — that
  provider raises unconditionally. This is deliberate: an `AUTH_ENABLED=true`
  misconfiguration fails loudly on the very first scope build (boot, see
  `Nucleus.Scope.verify_provider_at_boot!/0`), not silently on some later
  request.
  """
  @spec build(map()) :: {:ok, Scope.t()} | {:error, term()}
  def build(context) when is_map(context) do
    configured().build(context)
  end
end
