defmodule NucleusWeb.ScopeHookTest do
  use NucleusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Nucleus.Scope

  @endpoint NucleusWeb.Endpoint

  setup do
    original = Application.get_env(:nucleus, Scope)
    on_exit(fn -> Application.put_env(:nucleus, Scope, original) end)
    :ok
  end

  @tag :unit
  test "assigns current_scope from a scope already in the session", %{conn: conn} do
    scope = %Scope{user: %{email: "carol@example.com", username: nil}, tenant: "acme"}
    conn = Plug.Test.init_test_session(conn, %{current_scope: scope})

    {:ok, view, html} = live_isolated(conn, NucleusWeb.ScopeHookDemoLive)

    assert has_element?(view, "#scope-hook-demo-user", "carol@example.com")
    assert html =~ "carol@example.com"
  end

  @tag :unit
  test "builds a fresh scope, with source_ip from x-headers, when the session has none", %{
    conn: conn
  } do
    conn = Plug.Conn.put_req_header(conn, "x-forwarded-for", "9.8.7.6, 10.0.0.1")

    {:ok, view, _html} = live_isolated(conn, NucleusWeb.ScopeHookDemoLive)

    assert has_element?(view, "#scope-hook-demo-source-ip", "9.8.7.6")
  end

  @tag :unit
  test "rendered HTML never contains the token, even though the guard is what matters here", %{
    conn: conn
  } do
    scope = %Scope{
      user: %{email: "carol@example.com", username: nil},
      tenant: "acme",
      token: nil
    }

    conn = Plug.Test.init_test_session(conn, %{current_scope: scope})

    {:ok, _view, html} = live_isolated(conn, NucleusWeb.ScopeHookDemoLive)

    refute html =~ "token"
  end
end
