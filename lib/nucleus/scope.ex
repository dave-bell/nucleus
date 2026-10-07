defmodule Nucleus.Scope do
  @moduledoc """
  The current request/session identity — Phoenix 1.8's `current_scope` convention.

  Every authenticated LiveView and every audit record needs a `user` and a
  `tenant`; `AGENTS.md` is explicit that a missing `current_scope` assign
  produces its own error class. This struct is the seam: it exists so those
  call sites have a stable shape to read from, whether the identity behind it
  came from a real sign-in or (for the whole of EN-6) a single configured dev
  identity — see `Nucleus.Scope.Provider`.

  ## Fields

  - `user` — `%{email: String.t() | nil, username: String.t() | nil} | nil`.
    `nil` means unauthenticated; `authenticated?/1` is the read.
  - `tenant` — the tenant namespace this session is scoped to, from
    `tenant_namespace/0` (`TENANT_NAMESPACE`).
  - `scopes` — `[String.t()]`, the granted access scopes (`AUTH-A11` /
    `NAV-A08`). Always `[]` while auth is disabled.
  - `source_ip` — the caller's source IP, captured once at connect
    (`Plug.Conn` for a regular request, `get_connect_info/2` for a LiveView
    socket) because `X-Forwarded-For` is unavailable on later `handle_event`
    calls. EN-5's audit emitter reads this field, never a `Plug.Conn`.

  ## No token

  A scope carries no credential. Nucleus keeps no user token after sign-in and
  reaches every backend with a service credential instead — see
  `docs/adr/0038-session-based-authentication-no-token-passthrough.md` and
  `docs/adr/0039-tenant-api-service-credential.md`. This struct is written into
  the (signed, not encrypted) session cookie, so it must stay free of secrets.
  """

  require Logger

  alias Nucleus.Scope.Provider

  defstruct user: nil, tenant: nil, scopes: [], source_ip: nil

  @type user :: %{email: String.t() | nil, username: String.t() | nil}

  @type t :: %__MODULE__{
          user: user() | nil,
          tenant: String.t() | nil,
          scopes: [String.t()],
          source_ip: String.t() | nil
        }

  @doc """
  Whether `scope` carries a signed-in user.

      iex> Nucleus.Scope.authenticated?(%Nucleus.Scope{user: nil})
      false

      iex> Nucleus.Scope.authenticated?(%Nucleus.Scope{user: %{email: "a@b.com", username: nil}})
      true
  """
  @spec authenticated?(t()) :: boolean()
  def authenticated?(%__MODULE__{user: nil}), do: false
  def authenticated?(%__MODULE__{user: %{}}), do: true

  @doc """
  The identity to record on an audit event, per ADR-0002 §6 (wiki, reference
  only — re-verified here, not inherited): Cognito access tokens carry no
  `email` claim, so prefer email, fall back to username, and never leave an
  audit record with no identity at all.

      iex> Nucleus.Scope.audit_user(%Nucleus.Scope{user: %{email: "a@b.com", username: "auser"}})
      "a@b.com"

      iex> Nucleus.Scope.audit_user(%Nucleus.Scope{user: %{email: nil, username: "auser"}})
      "auser"

      iex> Nucleus.Scope.audit_user(%Nucleus.Scope{user: nil})
      "anonymous"
  """
  @spec audit_user(t()) :: String.t()
  def audit_user(%__MODULE__{user: %{email: email}}) when is_binary(email) and email != "" do
    email
  end

  def audit_user(%__MODULE__{user: %{username: username}})
      when is_binary(username) and username != "" do
    username
  end

  def audit_user(%__MODULE__{}), do: "anonymous"

  @doc """
  The tenant namespace every scope is built against.

  Read from `config :nucleus, Nucleus.Scope, tenant_namespace: ...`, set by
  `TENANT_NAMESPACE` in `config/runtime.exs`. Defaults to `"local"` so a fresh
  clone boots with no configuration at all.

      iex> Nucleus.Scope.tenant_namespace()
      "local"
  """
  @spec tenant_namespace() :: String.t()
  def tenant_namespace do
    Application.get_env(:nucleus, __MODULE__, [])
    |> Keyword.get(:tenant_namespace, "local")
  end

  @doc """
  Called once from `Nucleus.Application.start/2`.

  Verifies the configured `Nucleus.Scope.Provider` at boot rather than on first
  use, the same way `Nucleus.Backend.warn_on_local_backends/0` does:

  - `Nucleus.Scope.Provider.Disabled` (default, `AUTH_ENABLED=false`) never
    fails, and logs one prominent warning naming the assumed dev identity and
    tenant, so the insecure-but-convenient mode is never silently in effect.
  - `Nucleus.Scope.Provider.Cognito` (`AUTH_ENABLED=true`) has no identity to
    build until someone signs in, so the check is that its configuration is
    complete: `Nucleus.Auth.Config.verify!/0` raises otherwise. That raise
    propagates out of `start/2` and fails the boot - a loud failure at the
    earliest possible point, not a silent fallback or a broken first sign-in.
  """
  @spec verify_provider_at_boot!() :: :ok
  def verify_provider_at_boot! do
    case Provider.configured() do
      Nucleus.Scope.Provider.Disabled = provider ->
        {:ok, scope} = provider.build(%{})

        Logger.warning("""
        AUTH DISABLED - every session is assigned the dev identity below. This \
        must never reach a deployed environment; see AUTH_ENABLED and \
        docs/adr/0040-cognito-sign-in-and-session-lifecycle.md.
          * user   -> #{audit_user(scope)}
          * tenant -> #{scope.tenant}
          * scopes -> #{inspect(scope.scopes)}
        """)

        :ok

      _cognito ->
        Nucleus.Auth.Config.verify!()
    end
  end
end
