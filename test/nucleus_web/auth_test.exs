defmodule NucleusWeb.AuthTest do
  @moduledoc """
  Session enforcement with real sign-in on (`AUTH_ENABLED=true`): the
  `:assign_scope` plug for HTTP requests, `NucleusWeb.ScopeHook` for LiveView
  mounts, and logout. Sign-in itself is in `NucleusWeb.AuthControllerTest`.
  """

  use NucleusWeb.AuthCase

  import Phoenix.LiveViewTest,
    only: [live: 2, live_isolated: 2, element: 2, render_click: 1, follow_redirect: 2]

  alias Nucleus.Auth.{Config, Session, SessionRegistry}

  @endpoint NucleusWeb.Endpoint

  @protected ["/", "/applications", "/data-export", "/m2m/clients", "/environments/dev/secrets"]

  defp sync, do: :sys.get_state(SessionRegistry)

  defp record(session_id) do
    [{_id, record}] = :ets.lookup(SessionRegistry, session_id)
    record
  end

  describe "NAV-A10 / AUTH-A06 — no valid session redirects to sign-in" do
    @describetag action: "NAV-A10"

    test "every protected page redirects an unauthenticated visitor, returning to it", %{
      conn: conn
    } do
      for path <- @protected do
        conn = get(build_conn(), path)

        assert redirected_to(conn) == "/sign-in?return_to=" <> URI.encode_www_form(path),
               "#{path} must redirect to sign-in"

        assert conn.halted
      end

      _ = conn
    end

    test "carries the query string through", %{conn: conn} do
      conn = get(conn, "/environments/prod/secrets?tab=a&x=1")

      assert redirected_to(conn) ==
               "/sign-in?return_to=" <>
                 URI.encode_www_form("/environments/prod/secrets?tab=a&x=1")
    end

    test "returns no tenant data", %{conn: conn} do
      conn = get(conn, "/")

      assert conn.halted
      assert conn.status == 302
      refute conn.resp_body =~ "Applications"
      refute Map.has_key?(conn.assigns, :current_scope)
    end

    test "does not return a POST or DELETE to a path that was never meant to be a GET", %{
      conn: conn
    } do
      conn = post(conn, "/applications")
      assert conn.status in [302, 404, 405]
      refute conn.status == 302 and redirected_to(conn) =~ "return_to"
    end

    test "the sign-in page itself is public: no redirect loop", %{conn: conn} do
      assert conn |> get("/sign-in") |> Map.fetch!(:status) == 200
    end
  end

  describe "AUTH-A06 — never-signed-in and tampered sessions are silent" do
    @describetag action: "AUTH-A06"

    test "an ordinary first visit is not audited", %{conn: conn} do
      for path <- @protected, do: get(build_conn(), path)
      get(conn, "/")

      assert audit_events() == []
    end

    test "a tampered cookie is treated as no session: redirect, no audit", %{conn: conn} do
      conn = conn |> put_req_cookie("_nucleus_key", "tampered-garbage") |> get("/")

      assert redirected_to(conn) == "/sign-in?return_to=%2F"
      assert audit_events() == []
    end

    test "a cookie holding a forged auth entry is treated as no session", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{
          auth: %{"id" => "forged", "email" => "root@example.com"}
        })
        |> get("/")

      assert redirected_to(conn) == "/sign-in?return_to=%2F"
      assert audit_events() == []
    end

    test "auth_failure is never emitted for a redirect", %{conn: conn} do
      get(conn, "/")
      assert_no_audit_event(:auth_failure)
    end
  end

  describe "AUTH-A05 — a valid session is let through, and re-checked every request" do
    @describetag action: "AUTH-A05"

    test "assigns a scope built from the session", %{conn: conn} do
      {conn, _session} = sign_in_session(conn, email: "grace@example.com", username: "grace")
      conn = get(conn, "/")

      assert conn.status == 200
      assert conn.assigns.current_scope.user == %{email: "grace@example.com", username: "grace"}
      assert conn.assigns.current_scope.scopes == []
      assert audit_events() == []
    end

    test "captures the source IP", %{conn: conn} do
      {conn, _session} = sign_in_session(conn)
      conn = conn |> put_req_header("x-forwarded-for", "198.51.100.7") |> get("/")

      assert conn.assigns.current_scope.source_ip == "198.51.100.7"
    end

    test "a request counts as activity", %{conn: conn} do
      old = System.system_time(:second) - 60
      {conn, session} = sign_in_session(conn, signed_in_at: old, last_active: old)
      before = record(session.id).last_active

      get(conn, "/")
      sync()

      assert record(session.id).last_active > before
    end

    test "a session ended elsewhere stops working on the very next request", %{conn: conn} do
      {conn, session} = sign_in_session(conn)
      assert get(conn, "/").status == 200

      {:ok, _} = SessionRegistry.expire(Nucleus.Auth.SessionCheck.attrs(session), :idle)

      conn = conn |> recycle() |> get("/")
      assert redirected_to(conn) == "/sign-in?return_to=%2F"
    end

    test "a terminated session is refused", %{conn: conn} do
      {conn, session} = sign_in_session(conn)
      :ok = SessionRegistry.terminate_session(session.id)

      assert conn |> get("/") |> redirected_to() == "/sign-in?return_to=%2F"
    end

    test "a session the registry has forgotten (a restart) is restored from its cookie", %{
      conn: conn
    } do
      {conn, session} = sign_in_session(conn, register: false)
      assert SessionRegistry.status(session.id) == :unknown

      assert get(conn, "/").status == 200
      assert SessionRegistry.status(session.id) == :active
    end
  end

  describe "AUTH-A08 — idle timeout and max age end the session" do
    @describetag action: "AUTH-A08"

    test "a session idle past SESSION_IDLE_TIMEOUT is redirected and recorded as sign_out idle",
         %{conn: conn} do
      now = System.system_time(:second)

      {conn, _session} =
        sign_in_session(conn, signed_in_at: now - 1000, last_active: now - 1000, register: false)

      conn = get(conn, "/applications")

      assert redirected_to(conn) == "/sign-in?return_to=%2Fapplications"
      assert_audit_event(:sign_out, user: "ada@example.com", tenant: "local", reason: "idle")
    end

    test "a session past SESSION_MAX_AGE is redirected however recently it was active", %{
      conn: conn
    } do
      now = System.system_time(:second)

      {conn, _session} =
        sign_in_session(conn,
          signed_in_at: now - Config.max_age() - 1,
          last_active: now,
          register: false
        )

      conn = get(conn, "/")

      assert redirected_to(conn) == "/sign-in?return_to=%2F"
      assert_audit_event(:sign_out, reason: "max_age")
    end

    test "is recorded once however many requests discover it", %{conn: conn} do
      now = System.system_time(:second)

      {conn, _session} =
        sign_in_session(conn, signed_in_at: now - 1000, last_active: now - 1000, register: false)

      get(conn, "/")
      conn |> recycle() |> get("/")
      conn |> recycle() |> get("/")

      assert [_one] = Enum.filter(audit_events(), &(&1.event == :sign_out))
    end

    test "both limits are configurable", %{conn: conn} do
      put_auth_config(idle_timeout: 5, max_age: 3600)
      now = System.system_time(:second)

      {fresh, _} = sign_in_session(conn, last_active: now - 2)
      assert get(fresh, "/").status == 200

      {stale, _} = sign_in_session(build_conn(), last_active: now - 6, register: false)
      assert get(stale, "/").status == 302
    end

    test "a user who is just under the idle limit keeps their session", %{conn: conn} do
      now = System.system_time(:second)
      slack = Config.idle_timeout() - 30
      {conn, _} = sign_in_session(conn, signed_in_at: now - slack, last_active: now - slack)

      assert get(conn, "/").status == 200
      assert audit_events() == []
    end
  end

  describe "AUTH-A05 / AUTH-A06 — the LiveView mount authorizes independently" do
    @describetag action: "AUTH-A05"

    test "mounts for a valid session", %{conn: conn} do
      {conn, _session} = sign_in_session(conn, email: "grace@example.com")

      {:ok, view, _html} = live_isolated(conn, NucleusWeb.ScopeHookDemoLive)

      assert Phoenix.LiveViewTest.has_element?(view, "#scope-hook-demo-user", "grace@example.com")
    end

    test "halts, rather than mounting, for a session the registry has ended", %{conn: conn} do
      {conn, session} = sign_in_session(conn)
      {:ok, _} = SessionRegistry.expire(Nucleus.Auth.SessionCheck.attrs(session), :idle)

      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live_isolated(conn, NucleusWeb.ScopeHookDemoLive)
    end

    test "halts for a visitor with no session at all, silently", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live_isolated(conn, NucleusWeb.ScopeHookDemoLive)

      assert audit_events() == []
    end

    test "halts for a session past its max age and records sign_out max_age", %{conn: conn} do
      now = System.system_time(:second)

      {conn, _} =
        sign_in_session(conn, signed_in_at: now - Config.max_age() - 1, register: false)

      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live_isolated(conn, NucleusWeb.ScopeHookDemoLive)

      assert_audit_event(:sign_out, reason: "max_age")
    end

    test "does not mount the LiveView at all, so no tenant data is fetched", %{conn: conn} do
      {conn, session} = sign_in_session(conn)
      :ok = SessionRegistry.terminate_session(session.id)

      assert {:error, {:redirect, _}} = live(conn, "/applications") |> normalize()
    end

    defp normalize({:error, {:redirect, _}} = error), do: error
    defp normalize({:ok, _view, _html}), do: :mounted
    defp normalize(other), do: other
  end

  describe "AUTH-A09 — an expired session on a connected LiveView returns to the page it was on" do
    @describetag action: "AUTH-A09"

    test "remembers the page the session was on, as it navigates", %{conn: conn} do
      {conn, session} = sign_in_session(conn)

      {:ok, view, _html} = live(conn, "/applications")
      sync()
      assert SessionRegistry.last_path(session.id) == "/applications"

      # A navigate between LiveViews is a fresh mount of the next one; the test
      # client replays it as a request, which is the same mount hook either way.
      {:ok, _view, _html} =
        view |> element("#nav-data-export") |> render_click() |> follow_redirect(conn)

      sync()
      assert SessionRegistry.last_path(session.id) == "/data-export"
    end

    test "navigating after the session has ended sends the user to sign in", %{conn: conn} do
      {conn, session} = sign_in_session(conn)
      {:ok, view, _html} = live(conn, "/data-export")
      sync()

      {:ok, _} = SessionRegistry.expire(Nucleus.Auth.SessionCheck.attrs(session), :idle)

      assert {:error, {:redirect, %{to: "/sign-in?return_to=%2Fapplications"}}} =
               view
               |> element("#nav-applications")
               |> render_click()
               |> follow_redirect(conn)
    end

    test "a reconnecting tab is sent to sign-in with the page it was on", %{conn: conn} do
      {conn, session} = sign_in_session(conn)
      :ok = SessionRegistry.register(Nucleus.Auth.SessionCheck.attrs(session))
      SessionRegistry.touch(session.id, "/m2m/clients")
      sync()

      {:ok, _} = SessionRegistry.expire(Nucleus.Auth.SessionCheck.attrs(session), :max_age)

      assert {:error, {:redirect, %{to: "/sign-in?return_to=%2Fm2m%2Fclients"}}} =
               live_isolated(conn, NucleusWeb.ScopeHookDemoLive)
    end

    test "a hostile remembered path is never used", %{conn: conn} do
      {conn, session} = sign_in_session(conn)
      SessionRegistry.touch(session.id, "//evil.example.com")
      sync()
      {:ok, _} = SessionRegistry.expire(Nucleus.Auth.SessionCheck.attrs(session), :idle)

      assert {:error, {:redirect, %{to: "/sign-in"}}} =
               live_isolated(conn, NucleusWeb.ScopeHookDemoLive)
    end

    test "the end of the session disconnects every open tab", %{conn: conn} do
      {_conn, session} = sign_in_session(conn)
      NucleusWeb.Endpoint.subscribe(Session.live_socket_id(session))

      {:ok, record} = SessionRegistry.expire(Nucleus.Auth.SessionCheck.attrs(session), :idle)
      SessionRegistry.announce_expiry(record, :idle)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end

  describe "AUTH-A08 — activity on a connected tab keeps the session alive" do
    @describetag action: "AUTH-A08"

    test "an event counts as activity", %{conn: conn} do
      put_auth_config(activity_throttle_ms: 0)
      old = System.system_time(:second) - 60
      {conn, session} = sign_in_session(conn, signed_in_at: old, last_active: old)
      {:ok, view, _html} = live(conn, "/")
      sync()
      before = record(session.id).last_active

      view |> element("#user-menu button") |> render_click()
      sync()

      assert record(session.id).last_active > before
    end

    test "events are throttled", %{conn: conn} do
      put_auth_config(activity_throttle_ms: :timer.hours(1))
      {conn, session} = sign_in_session(conn)
      {:ok, view, _html} = live(conn, "/")
      sync()
      before = record(session.id).last_active

      view |> element("#user-menu button") |> render_click()
      sync()

      assert record(session.id).last_active == before
    end

    test "navigation always counts, throttle or not", %{conn: conn} do
      put_auth_config(activity_throttle_ms: :timer.hours(1))
      old = System.system_time(:second) - 60
      {conn, session} = sign_in_session(conn, signed_in_at: old, last_active: old)
      {:ok, view, _html} = live(conn, "/")
      sync()
      before = record(session.id).last_active

      {:ok, _view, _html} =
        view |> element("#nav-data-export") |> render_click() |> follow_redirect(conn)

      sync()

      assert record(session.id).last_active > before
      assert SessionRegistry.last_path(session.id) == "/data-export"
    end

    test "an event does not re-validate the session: the guarantee is per request and mount", %{
      conn: conn
    } do
      {conn, session} = sign_in_session(conn)
      {:ok, view, _html} = live(conn, "/")

      {:ok, _} = SessionRegistry.expire(Nucleus.Auth.SessionCheck.attrs(session), :idle)

      # AUTH-A05: no per-handle_event check. The click is served.
      assert view |> element("#user-menu button") |> render_click() =~ "user-menu-panel"
    end
  end

  describe "logout" do
    @describetag action: "NAV-A08"

    test "ends the session, records sign_out user, and lands on sign-in", %{conn: conn} do
      {conn, session} = sign_in_session(conn)
      conn = delete(conn, "/logout")

      assert redirected_to(conn) == "/sign-in"
      assert SessionRegistry.status(session.id) == {:expired, :user}
      assert_audit_event(:sign_out, user: "ada@example.com", reason: "user")
    end

    test "kills a copy of the old cookie too", %{conn: conn} do
      {conn, _session} = sign_in_session(conn)
      delete(conn, "/logout")

      assert conn |> recycle() |> get("/") |> redirected_to() =~ "/sign-in"
      assert [_one] = Enum.filter(audit_events(), &(&1.event == :sign_out))
    end

    test "logging out twice records one sign_out", %{conn: conn} do
      {conn, _session} = sign_in_session(conn)
      delete(conn, "/logout")
      conn |> recycle() |> delete("/logout")

      assert [_one] = Enum.filter(audit_events(), &(&1.event == :sign_out))
    end

    test "disconnects the session's tabs", %{conn: conn} do
      {conn, session} = sign_in_session(conn)
      NucleusWeb.Endpoint.subscribe(Session.live_socket_id(session))

      delete(conn, "/logout")

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "without a session there is nothing to record", %{conn: conn} do
      conn = delete(conn, "/logout")

      assert redirected_to(conn) == "/sign-in"
      assert audit_events() == []
    end
  end
end
