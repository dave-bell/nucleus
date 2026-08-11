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
  - `token` — the user's access token, for passthrough to backing APIs.
    **Always `nil` for the whole of EN-6.** The field exists now so that
    retrofitting it later is a substitution, not a refactor of every
    backing-API call site — see `docs/adr/0005-deferred-authentication.md`.
    Never populate this with a fabricated value.
  - `scopes` — `[String.t()]`, the granted access scopes (`AUTH-A11` /
    `NAV-A08`). Always `[]` while auth is disabled.
  - `source_ip` — the caller's source IP, captured once at connect
    (`Plug.Conn` for a regular request, `get_connect_info/2` for a LiveView
    socket) because `X-Forwarded-For` is unavailable on later `handle_event`
    calls. EN-5's audit emitter reads this field, never a `Plug.Conn`.

  ## Never render this struct wholesale

  LiveView diffs *rendered output*, not raw assigns — a token sitting in
  `socket.assigns.current_scope.token` is never shipped to the client unless
  something renders it. That is a constraint on template authors, not an
  ambient guarantee: never write `inspect(@current_scope)` or similar in a
  debug block, in this ticket or later once `token` is populated.
  """

  require Logger

  alias Nucleus.Scope.Provider

  defstruct user: nil, tenant: nil, token: nil, scopes: [], source_ip: nil

  @type user :: %{email: String.t() | nil, username: String.t() | nil}

  @type t :: %__MODULE__{
          user: user() | nil,
          tenant: String.t() | nil,
          token: String.t() | nil,
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

  Builds a scope through the configured `Nucleus.Scope.Provider` unconditionally,
  the same way `Nucleus.Backend.warn_on_local_backends/0` verifies backend
  configuration at boot rather than on first use:

  - `Nucleus.Scope.Provider.Disabled` (default, `AUTH_ENABLED=false`) never
    fails, so this always succeeds — and logs one prominent warning naming the
    assumed dev identity and tenant, so the insecure-but-convenient mode is
    never silently in effect.
  - `Nucleus.Scope.Provider.Cognito` (`AUTH_ENABLED=true`) raises
    unconditionally. That raise propagates straight out of `start/2` and fails
    the boot — a loud failure at the earliest possible point, not a silent
    fallback to the disabled provider on the first request.
  """
  @spec verify_provider_at_boot!() :: :ok
  def verify_provider_at_boot! do
    provider = Provider.configured()
    {:ok, scope} = provider.build(%{})

    if provider == Nucleus.Scope.Provider.Disabled do
      Logger.warning("""
      AUTH DISABLED — every session is assigned the dev identity below. This \
      must never reach a deployed environment; see AUTH_ENABLED and \
      docs/adr/0005-deferred-authentication.md.
        * user   -> #{audit_user(scope)}
        * tenant -> #{scope.tenant}
        * scopes -> #{inspect(scope.scopes)}
      """)
    end

    :ok
  end
end
