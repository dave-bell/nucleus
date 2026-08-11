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
  end
end
