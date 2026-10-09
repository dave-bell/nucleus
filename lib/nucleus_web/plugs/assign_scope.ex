defmodule NucleusWeb.Plugs.AssignScope do
  @moduledoc """
  Authorizes the request and assigns `conn.assigns.current_scope` on every
  `:assign_scope` request.

  Builds the scope through `Nucleus.Scope.Provider.build/1`, capturing
  `source_ip` here — via `Nucleus.Audit.Source.from_conn/1` — because this is
  the last point at which a `Plug.Conn` (and so `X-Forwarded-For`) exists.
  `NucleusWeb.ScopeHook` reads the same source IP back out of the session for
  the LiveView socket that outlives this request.

  ## Authorization (`AUTH_ENABLED=true`)

  With the Cognito provider this is the HTTP half of `AUTH-A05` (the LiveView
  half is `NucleusWeb.ScopeHook`): every request re-validates the session
  through `Nucleus.Auth.SessionCheck` - signature (a tampered or undecryptable
  cookie arrives here as an empty session), `SESSION_MAX_AGE`,
  `SESSION_IDLE_TIMEOUT`, and the registry's verdict. A request that fails is
  redirected to `/sign-in`, carrying the page it asked for as `return_to`
  (`AUTH-A03`, `NAV-A10`) and **halted**, so no tenant data is rendered.

  A visitor who was simply never signed in is redirected without an audit
  event; one whose session expired is recorded as `sign_out`
  (`reason=idle|max_age`) by `SessionCheck`, once. `auth_failure` is not
  emitted here: it belongs to callback failures (`AUTH-A06`).

  With `AUTH_ENABLED=false` the dev scope is assigned and nothing is checked.

  The scope is also stored in the session. `Nucleus.Scope` has no token field,
  so there is nothing credential-shaped to force out of it: the struct simply
  cannot carry one, whatever the cookie's protection (it is signed and
  encrypted, `NucleusWeb.Endpoint`).

  ## `nav_session_id`

  Also mints a random, identity-independent id — `nav_session_id` — the
  first time a browser session has none, and leaves it alone on every later
  request (so it stays stable for that browser's session cookie). This is
  deliberately *not* derived from `current_scope`: `NucleusWeb.SidebarNavState`
  keys the sidebar's per-session expand/collapse state by it, and
  `AUTH_ENABLED=false` means `current_scope` is the same dev identity for
  every request right now — a fine key for "which environments can this
  request see," a bad one for "which browser tab is this."
  """

  import Plug.Conn

  alias Nucleus.Audit
  alias Nucleus.Auth.SessionCheck
  alias Nucleus.Scope
  alias NucleusWeb.ReturnTo

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    source_ip = Audit.Source.from_conn(conn)

    if Scope.Provider.configured() == Scope.Provider.Cognito do
      authorize(conn, source_ip)
    else
      {:ok, scope} = Scope.Provider.build(%{source_ip: source_ip})
      conn |> assign_scope(scope) |> ensure_nav_session_id()
    end
  end

  defp authorize(conn, source_ip) do
    case SessionCheck.validate(get_session(conn)) do
      {:ok, auth} ->
        {:ok, scope} = Scope.Provider.build(%{session: auth, source_ip: source_ip})

        conn
        |> assign_scope(scope)
        |> put_session(:auth, auth)
        |> ensure_nav_session_id()

      {:error, _no_valid_session} ->
        conn
        |> Phoenix.Controller.redirect(to: ReturnTo.sign_in_path(ReturnTo.from_conn(conn)))
        |> halt()
    end
  end

  defp assign_scope(conn, scope) do
    conn
    |> assign(:current_scope, scope)
    |> put_session(:current_scope, scope)
  end

  defp ensure_nav_session_id(conn) do
    case get_session(conn, :nav_session_id) do
      nil -> put_session(conn, :nav_session_id, generate_nav_session_id())
      _existing -> conn
    end
  end

  defp generate_nav_session_id do
    Base.url_encode64(:crypto.strong_rand_bytes(16))
  end
end
