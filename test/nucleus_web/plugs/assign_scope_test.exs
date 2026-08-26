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

  @tag :unit
  test "mints a nav_session_id into the session", %{conn: conn} do
    conn = AssignScope.call(conn, [])

    assert is_binary(Plug.Conn.get_session(conn, :nav_session_id))
  end

  @tag :unit
  test "a request that already has a nav_session_id keeps it, rather than minting a new one", %{
    conn: conn
  } do
    conn = Plug.Conn.put_session(conn, :nav_session_id, "existing-id")

    conn = AssignScope.call(conn, [])

    assert Plug.Conn.get_session(conn, :nav_session_id) == "existing-id"
  end

  @tag :unit
  test "two separate requests get two different nav_session_ids", %{conn: conn} do
    other_conn = Plug.Test.init_test_session(Phoenix.ConnTest.build_conn(), %{})

    conn = AssignScope.call(conn, [])
    other_conn = AssignScope.call(other_conn, [])

    refute Plug.Conn.get_session(conn, :nav_session_id) ==
             Plug.Conn.get_session(other_conn, :nav_session_id)
  end
end
