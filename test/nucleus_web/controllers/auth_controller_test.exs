defmodule NucleusWeb.AuthControllerTest do
  use NucleusWeb.AuthCase

  alias Nucleus.Auth.Session

  defp page(conn) do
    conn |> html_response(conn.status) |> LazyHTML.from_fragment()
  end

  defp present?(conn, selector), do: conn |> page() |> LazyHTML.query(selector) |> Enum.any?()

  # Runs the whole round trip against the stubbed Cognito and returns the
  # callback's response conn.
  defp complete_sign_in(conn, key, opts \\ []) do
    {conn, sent} = begin_sign_in(conn, Keyword.get(opts, :start_params, %{}))
    claims = Keyword.get(opts, :claims, %{})
    token = id_token(key, Keyword.get(opts, :nonce, sent.nonce), claims)

    stub_cognito(keys: [key], token: Keyword.get(opts, :token, {:ok, token}))

    callback_params = Keyword.get(opts, :params, %{"code" => "the-code", "state" => sent.state})

    conn
    |> recycle()
    |> put_req_header("x-forwarded-for", "203.0.113.9")
    |> get(~p"/auth/callback", callback_params)
  end

  defp failed?(conn, reason) do
    assert conn.status == 400
    assert present?(conn, "#sign-in-failure")
    assert get_session(conn, :auth) == nil
    assert_audit_event(:auth_failure, reason: reason, user: "anonymous", tenant: "local")
    assert_no_audit_event(:sign_in)
  end

  describe "GET /sign-in" do
    @describetag action: "AUTH-A01"

    test "identifies the application and offers one Sign in with SSO action", %{conn: conn} do
      conn = get(conn, ~p"/sign-in")

      assert conn.status == 200
      assert present?(conn, "#sign-in-page")
      assert present?(conn, "#sign-in-form")
      assert present?(conn, "#sign-in-sso")
      assert conn |> page() |> LazyHTML.text() =~ "Nucleus"
    end

    test "never presents username or password fields", %{conn: conn} do
      conn = get(conn, ~p"/sign-in")

      refute present?(conn, "input[type=password]")
      refute present?(conn, "input[name*=password]")
      refute present?(conn, "input[type=email]")
      refute present?(conn, "input[type=text]")
    end

    test "is not itself an audited event", %{conn: conn} do
      get(conn, ~p"/sign-in")
      assert audit_events() == []
    end

    test "redirects an already signed-in visitor on to where they were going", %{conn: conn} do
      {conn, _session} = sign_in_session(conn)

      assert conn |> get(~p"/sign-in", %{"return_to" => "/data-export"}) |> redirected_to() ==
               "/data-export"

      {conn, _session} = sign_in_session(build_conn())
      assert conn |> get(~p"/sign-in") |> redirected_to() == "/"
    end

    test "starts a visitor with a dead session from a clean slate", %{conn: conn} do
      {conn, _} =
        sign_in_session(conn,
          signed_in_at: System.system_time(:second) - 100_000,
          register: false
        )

      conn = get(conn, ~p"/sign-in")

      assert conn.status == 200
      assert get_session(conn, :auth) == nil
    end
  end

  describe "POST /sign-in" do
    @describetag action: "AUTH-A02"

    test "redirects to the Cognito Hosted UI with state, nonce and PKCE", %{conn: conn} do
      {_conn, sent} = begin_sign_in(conn)

      assert sent.url =~ "https://auth.example.test/oauth2/authorize?"
      assert sent.query["response_type"] == "code"
      assert sent.query["client_id"] == client_id()
      assert sent.query["code_challenge_method"] == "S256"
      assert sent.query["code_challenge"]
      assert sent.query["state"] == sent.state
      assert sent.query["nonce"] == sent.nonce
      assert sent.query["scope"] == "openid email"
    end

    test "never sends the client secret to the browser", %{conn: conn} do
      {_conn, sent} = begin_sign_in(conn)
      refute sent.url =~ client_secret()
    end

    test "keeps state and nonce server-verifiable, and mints fresh ones each time", %{conn: conn} do
      {conn1, a} = begin_sign_in(conn)
      {_conn2, b} = begin_sign_in(build_conn())

      assert get_session(conn1, :auth_pending).state == a.state
      refute a.state == b.state
      refute a.nonce == b.nonce
    end
  end

  describe "GET /auth/callback — a successful sign-in" do
    @describetag action: "AUTH-A02"

    test "writes a session, redirects home, and records sign_in", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key)

      assert redirected_to(conn) == "/"
      assert %Session{email: "ada@example.com", username: "ada"} = auth = get_session(conn, :auth)
      assert get_session(conn, :live_socket_id) == "auth_sessions:" <> auth.id
      assert get_session(conn, :auth_pending) == nil

      assert_audit_event(:sign_in,
        user: "ada@example.com",
        tenant: "local",
        source_ip: "203.0.113.9"
      )

      assert_no_audit_event(:auth_failure)
    end

    test "exchanges the code as a confidential client, with the PKCE verifier", %{
      conn: conn,
      key: key
    } do
      complete_sign_in(conn, key)

      assert_received {:token_request, form, authorization}
      assert form["code"] == "the-code"
      assert form["code_verifier"] =~ ~r/\A[A-Za-z0-9_-]{43}\z/
      assert authorization == "Basic " <> Base.encode64("#{client_id()}:#{client_secret()}")
    end

    test "keeps no token: not the access token, not the refresh token, not the ID token",
         %{conn: conn, key: key} do
      {conn, sent} = begin_sign_in(conn)
      token = id_token(key, sent.nonce)
      stub_cognito(keys: [key], token: {:ok, token})

      conn = conn |> recycle() |> get(~p"/auth/callback", %{"code" => "c", "state" => sent.state})

      session = inspect(get_session(conn))
      refute session =~ "must-never-be-kept"
      refute session =~ token
      refute session =~ client_secret()
      refute Enum.any?(get_session(conn), fn {_k, v} -> is_binary(v) and v == token end)
    end

    test "registers the session with the session registry", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key)
      %Session{id: id} = get_session(conn, :auth)

      assert Nucleus.Auth.SessionRegistry.status(id) == :active
    end

    test "replaces whatever session the visitor had before", %{conn: conn, key: key} do
      {conn, _old} = sign_in_session(conn, email: "someone-else@example.com")
      conn = Plug.Conn.put_session(conn, :leftover, "stale")

      {conn, sent} = begin_sign_in(conn)
      stub_cognito(keys: [key], token: {:ok, id_token(key, sent.nonce)})
      conn = conn |> recycle() |> get(~p"/auth/callback", %{"code" => "c", "state" => sent.state})

      assert get_session(conn, :auth).email == "ada@example.com"
      assert get_session(conn, :leftover) == nil
    end

    test "a sign-in attempt can be completed only once", %{conn: conn, key: key} do
      {conn, sent} = begin_sign_in(conn)
      stub_cognito(keys: [key], token: {:ok, id_token(key, sent.nonce)})
      params = %{"code" => "c", "state" => sent.state}

      conn = conn |> recycle() |> get(~p"/auth/callback", params)
      assert redirected_to(conn) == "/"

      # Same browser, same URL again. The attempt is spent, so it fails: but a
      # bad callback does not sign out a session that is already valid.
      replay = conn |> recycle() |> get(~p"/auth/callback", params)
      assert replay.status == 400
      assert_audit_event(:auth_failure, reason: "state_missing")
    end
  end

  describe "AUTH-A03 — landing on the page the user asked for" do
    @describetag action: "AUTH-A03"

    test "returns to the originally requested URL", %{conn: conn, key: key} do
      conn =
        complete_sign_in(conn, key,
          start_params: %{"return_to" => "/environments/prod/secrets?tab=a"}
        )

      assert redirected_to(conn) == "/environments/prod/secrets?tab=a"
    end

    test "goes to the default view when sign-in began at the sign-in page", %{
      conn: conn,
      key: key
    } do
      assert conn |> complete_sign_in(key) |> redirected_to() == "/"
    end

    test "the sign-in page carries return_to through its form", %{conn: conn} do
      conn = get(conn, ~p"/sign-in", %{"return_to" => "/data-export"})

      assert conn
             |> page()
             |> LazyHTML.query("input[name=return_to]")
             |> LazyHTML.attribute("value") ==
               ["/data-export"]
    end

    test "refuses to be an open redirect", %{conn: conn, key: key} do
      for hostile <- ["//evil.example.com", "https://evil.example.com", "/\\evil.example.com"] do
        conn = complete_sign_in(build_conn(), key, start_params: %{"return_to" => hostile})
        assert redirected_to(conn) == "/", "#{hostile} must fall back to the default view"
      end

      _ = conn
    end

    test "the sign-in page does not render a hostile return_to into its form", %{conn: conn} do
      conn = get(conn, ~p"/sign-in", %{"return_to" => "//evil.example.com"})
      refute present?(conn, "input[name=return_to]")
    end
  end

  describe "AUTH-A04 — a user outside the authorized group" do
    @describetag action: "AUTH-A04"

    test "is shown access denied, with no session", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key, claims: %{"cognito:groups" => ["someone-elses-group"]})

      assert conn.status == 403
      assert present?(conn, "#access-denied")
      assert get_session(conn, :auth) == nil
    end

    test "is recorded as auth_failure with the user, the reason and the source IP", %{
      conn: conn,
      key: key
    } do
      complete_sign_in(conn, key, claims: %{"cognito:groups" => []})

      assert_audit_event(:auth_failure,
        user: "ada@example.com",
        tenant: "local",
        source_ip: "203.0.113.9",
        reason: "not_in_authorized_group"
      )

      assert_no_audit_event(:sign_in)
    end

    test "a user with no groups claim at all is denied", %{conn: conn, key: key} do
      {conn, sent} = begin_sign_in(conn)

      claims =
        Nucleus.AuthFixtures.claims(%{"nonce" => sent.nonce}) |> Map.delete("cognito:groups")

      stub_cognito(keys: [key], token: {:ok, sign(key, claims)})

      conn = conn |> recycle() |> get(~p"/auth/callback", %{"code" => "c", "state" => sent.state})

      assert conn.status == 403
      assert get_session(conn, :auth) == nil
    end
  end

  describe "AUTH-A02 — every failure is a generic page and an auth_failure, never a crash" do
    @describetag action: "AUTH-A02"

    test "the user cancelled or the IdP refused (?error=)", %{conn: conn, key: key} do
      conn =
        complete_sign_in(conn, key,
          params: %{"error" => "access_denied", "error_description" => "User cancelled"}
        )

      failed?(conn, "idp_error:access_denied")
    end

    test "an ?error= code is never echoed into the audit record unsanitized", %{
      conn: conn,
      key: key
    } do
      conn = complete_sign_in(conn, key, params: %{"error" => "<script>alert(1)</script>"})

      failed?(conn, "idp_error:unknown")
      refute_audit_contains("<script>")
    end

    test "a state mismatch", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key, params: %{"code" => "c", "state" => "forged"})
      failed?(conn, "state_mismatch")
    end

    test "a missing state", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key, params: %{"code" => "c"})
      failed?(conn, "state_mismatch")
    end

    test "a callback with no sign-in in progress", %{conn: conn} do
      conn = get(conn, ~p"/auth/callback", %{"code" => "c", "state" => "anything"})
      failed?(conn, "state_missing")
    end

    test "a missing code", %{conn: conn, key: key} do
      {conn, sent} = begin_sign_in(conn)
      stub_cognito(keys: [key])

      conn = conn |> recycle() |> get(~p"/auth/callback", %{"state" => sent.state})
      failed?(conn, "missing_code")
    end

    test "the token endpoint rejects the code", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key, token: {:status, 400})
      failed?(conn, "token_exchange_failed")
    end

    test "the token endpoint is unreachable", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key, token: :transport_error)
      failed?(conn, "token_endpoint_unreachable")
    end

    test "the token endpoint returns no ID token", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key, token: {:body, %{"access_token" => "x"}})
      failed?(conn, "token_exchange_failed")
    end

    test "an ID token carrying a nonce we did not send", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key, nonce: "a-replayed-nonce")
      failed?(conn, "invalid_id_token:nonce_mismatch")
    end

    test "an ID token signed by a key that is not the pool's", %{conn: conn, key: key} do
      {conn, sent} = begin_sign_in(conn)
      stub_cognito(keys: [key], token: {:ok, id_token(generate_key("suite-key"), sent.nonce)})

      conn = conn |> recycle() |> get(~p"/auth/callback", %{"code" => "c", "state" => sent.state})
      failed?(conn, "invalid_id_token:invalid_signature")
    end

    test "an ID token meant for a different client", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key, claims: %{"aud" => "another-client"})
      failed?(conn, "invalid_id_token:invalid_audience")
    end

    test "an expired ID token", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key, claims: %{"exp" => System.system_time(:second) - 3600})
      failed?(conn, "invalid_id_token:expired")
    end

    test "the page says nothing about why", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key, params: %{"code" => "c", "state" => "forged"})
      text = conn |> page() |> LazyHTML.text()

      refute text =~ ~r/state|nonce|token|csrf/i
    end

    test "records the caller's source IP", %{conn: conn, key: key} do
      conn = complete_sign_in(conn, key, params: %{"error" => "access_denied"})
      assert conn.status == 400
      assert_audit_event(:auth_failure, source_ip: "203.0.113.9")
    end
  end

  describe "with authentication disabled" do
    test "the sign-in routes send the browser home", %{conn: conn} do
      Application.put_env(:nucleus, Nucleus.Scope, provider: Nucleus.Scope.Provider.Disabled)

      assert conn |> get(~p"/sign-in") |> redirected_to() == "/"
      assert build_conn() |> post(~p"/sign-in") |> redirected_to() == "/"
      assert build_conn() |> get(~p"/auth/callback") |> redirected_to() == "/"
    end
  end
end
