defmodule NucleusWeb.Plugs.AssignScope do
  @moduledoc """
  Assigns `conn.assigns.current_scope` on every `:browser` request.

  Builds the scope through `Nucleus.Scope.Provider.build/1`, capturing
  `source_ip` here — via `Nucleus.Audit.Source.from_conn/1` — because this is
  the last point at which a `Plug.Conn` (and so `X-Forwarded-For`) exists.
  `NucleusWeb.ScopeHook` reads the same source IP back out of the session for
  the LiveView socket that outlives this request.

  The scope is also stored in the session, with `token` forced to `nil`
  regardless of what the provider returned — the session is a signed, not
  encrypted, cookie, and this is a defensive floor: it costs nothing today,
  because EN-6 never populates `token`, and it means a future provider change
  cannot leak a token into the session by omission.

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
  alias Nucleus.Scope

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    source_ip = Audit.Source.from_conn(conn)

    {:ok, scope} = Scope.Provider.build(%{source_ip: source_ip})

    conn
    |> assign(:current_scope, scope)
    |> put_session(:current_scope, %{scope | token: nil})
    |> ensure_nav_session_id()
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
