defmodule NucleusWeb.Plugs.AssignScopeTest do
  use NucleusWeb.ConnCase, async: false

  alias Nucleus.Scope
  alias NucleusWeb.Plugs.AssignScope

  setup %{conn: conn} do
    original = Application.get_env(:nucleus, Scope)
    on_exit(fn -> Application.put_env(:nucleus, Scope, original) end)

    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  @tag :unit
  test "assigns current_scope", %{conn: conn} do
    conn = AssignScope.call(conn, [])

    assert %Scope{} = conn.assigns.current_scope
  end

  @tag :unit
  test "stores the scope in the session, with token forced to nil", %{conn: conn} do
    conn = AssignScope.call(conn, [])

    assert %Scope{token: nil} = Plug.Conn.get_session(conn, :current_scope)
  end

  @tag :unit
  test "captures source_ip from X-Forwarded-For, first entry", %{conn: conn} do
    conn =
      conn
      |> Plug.Conn.put_req_header("x-forwarded-for", "1.2.3.4, 10.0.0.1")
      |> AssignScope.call([])

    assert conn.assigns.current_scope.source_ip == "1.2.3.4"
  end

  @tag :unit
  test "AUTH_ENABLED=true raises rather than falling back to the disabled provider", %{
    conn: conn
  } do
    Application.put_env(:nucleus, Scope, provider: Nucleus.Scope.Provider.Cognito)

    assert_raise RuntimeError, ~r/AUTH-A01\.\.A11/, fn ->
      AssignScope.call(conn, [])
    end
  end
end
