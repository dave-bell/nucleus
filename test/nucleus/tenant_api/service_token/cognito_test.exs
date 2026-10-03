defmodule Nucleus.TenantApi.ServiceToken.CognitoTest do
  # Configuration is application-global, so these cannot run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Several cases deliberately provoke a failure, which logs a warning. The
  # logging assertions below read what they capture themselves.
  @moduletag :capture_log

  alias Nucleus.Backend.Error
  alias Nucleus.TenantApi.ServiceToken.Cognito

  @stub __MODULE__
  @secret "shhh-client-secret"
  @token "eyJ.the-access-token.sig"

  setup do
    original = Application.get_env(:nucleus, Cognito)
    on_exit(fn -> Application.put_env(:nucleus, Cognito, original) end)
    configure()
    :ok
  end

  defp configure(overrides \\ []) do
    Application.put_env(
      :nucleus,
      Cognito,
      Keyword.merge(
        [
          domain: "auth.example.com",
          client_id: "nucleus-api",
          client_secret: @secret,
          scope: "tenant/api",
          region: "us-east-1",
          user_pool_id: "us-east-1_AbC123",
          plug: {Req.Test, @stub}
        ],
        overrides
      )
    )
  end

  defp stub(fun), do: Req.Test.stub(@stub, fun)

  defp respond(status, body) do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, body)
    end)
  end

  defp grant_body(overrides \\ %{}) do
    Jason.encode!(
      Map.merge(
        %{"access_token" => @token, "expires_in" => 3600, "token_type" => "Bearer"},
        overrides
      )
    )
  end

  # The suite runs at :warning, which filters :info before a capture handler sees
  # it; a successful call logs at :info.
  defp capture_info(fun) do
    original = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original) end)

    capture_log(fun)
  end

  describe "the request" do
    test "is a client-credentials POST to the token endpoint on the configured host" do
      test_pid = self()

      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, conn, body})
        Plug.Conn.resp(conn, 200, grant_body())
      end)

      assert {:ok, _grant} = Cognito.request_token()

      assert_received {:request, conn, body}
      assert conn.method == "POST"
      assert conn.scheme == :https
      assert conn.host == "auth.example.com"
      assert conn.request_path == "/oauth2/token"

      assert ["application/x-www-form-urlencoded" <> _] =
               Plug.Conn.get_req_header(conn, "content-type")

      assert URI.decode_query(body) == %{
               "grant_type" => "client_credentials",
               "scope" => "tenant/api"
             }
    end

    test "authenticates the client with HTTP Basic" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
        Plug.Conn.resp(conn, 200, grant_body())
      end)

      assert {:ok, _grant} = Cognito.request_token()

      assert_received {:authorization, ["Basic " <> encoded]}
      assert Base.decode64!(encoded) == "nucleus-api:#{@secret}"
    end

    test "does not follow a redirect, which would carry the client secret elsewhere" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://attacker.example.com/oauth2/token")
        |> Plug.Conn.resp(302, "")
      end)

      assert {:error, %Error{kind: :unavailable, details: %{status: 302}}} =
               Cognito.request_token()
    end
  end

  describe "a successful response" do
    test "is the token and its lifetime" do
      respond(200, grant_body(%{"expires_in" => 1800}))

      assert Cognito.request_token() == {:ok, %{token: @token, expires_in: 1800}}
    end
  end

  describe "the token endpoint rejecting our client" do
    for status <- [400, 401] do
      test "#{status} is :auth_expired" do
        respond(unquote(status), ~s({"error": "invalid_client"}))

        assert {:error,
                %Error{kind: :auth_expired, boundary: :service_token, details: %{status: status}}} =
                 Cognito.request_token()

        assert status == unquote(status)
      end
    end
  end

  describe "the token endpoint being unavailable" do
    for status <- [403, 404, 429, 500, 502, 503] do
      test "#{status} is :unavailable" do
        respond(unquote(status), "{}")

        assert {:error, %Error{kind: :unavailable, details: %{status: status}}} =
                 Cognito.request_token()

        assert status == unquote(status)
      end
    end

    test "a transport failure is :unavailable" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Error{kind: :unavailable, details: %{reason: reason}}} =
               Cognito.request_token()

      assert reason =~ "econnrefused"
    end

    for {label, body} <- [
          {"not JSON", "{not json"},
          {"a JSON array", "[]"},
          {"missing the token", ~s({"expires_in": 3600})},
          {"missing the lifetime", ~s({"access_token": "tok"})},
          {"a blank token", ~s({"access_token": "", "expires_in": 3600})},
          {"a zero lifetime", ~s({"access_token": "tok", "expires_in": 0})},
          {"a string lifetime", ~s({"access_token": "tok", "expires_in": "3600"})}
        ] do
      test "a 200 whose body is #{label} is :unavailable" do
        respond(200, unquote(body))

        assert {:error, %Error{kind: :unavailable}} = Cognito.request_token()
      end
    end
  end

  describe "missing configuration" do
    for {key, variable} <- [
          domain: "COGNITO_DOMAIN",
          client_id: "COGNITO_CLIENT_ID_API",
          client_secret: "COGNITO_CLIENT_SECRET_API",
          scope: "COGNITO_SCOPE"
        ],
        {label, value} <- [{"unset", nil}, {"blank", ""}] do
      test "#{label} #{key} is :not_configured, naming #{variable}, with no request" do
        configure([{unquote(key), unquote(value)}])
        test_pid = self()

        stub(fn conn ->
          send(test_pid, :request_attempted)
          Plug.Conn.resp(conn, 200, grant_body())
        end)

        assert {:error, %Error{kind: :not_configured, details: %{variable: variable}}} =
                 Cognito.request_token()

        assert variable == unquote(variable)
        refute_received :request_attempted
      end
    end

    for {label, domain} <- [
          {"a URL with a scheme", "https://auth.example.com"},
          {"a host with a path", "auth.example.com/oauth2"},
          {"a host with userinfo", "user@auth.example.com"},
          {"a host with a space", "auth example.com"},
          {"only a dot", "."}
        ] do
      test "a domain that is #{label} is :not_configured, with no request" do
        configure(domain: unquote(domain))
        test_pid = self()

        stub(fn conn ->
          send(test_pid, :request_attempted)
          Plug.Conn.resp(conn, 200, grant_body())
        end)

        assert {:error, %Error{kind: :not_configured, details: %{variable: "COGNITO_DOMAIN"}}} =
                 Cognito.request_token()

        refute_received :request_attempted
      end
    end

    test "a bare host with a port is accepted" do
      configure(domain: "localhost:8443")
      respond(200, grant_body())

      assert {:ok, _grant} = Cognito.request_token()
    end
  end

  describe "secrecy" do
    test "a success logs the status and a request id, never the secret, token or body" do
      respond(200, grant_body())

      log = capture_info(fn -> Cognito.request_token() end)

      assert log =~ "-> 200"
      assert log =~ ~r/request_id=[0-9a-f]{16}/
      refute log =~ @secret
      refute log =~ @token
      refute log =~ "Basic"
    end

    test "a rejection logs the status, and not a body that may echo the request" do
      respond(400, ~s({"error": "invalid_client", "echo": "#{@secret}"}))

      log = capture_info(fn -> Cognito.request_token() end)

      assert log =~ "-> 400"
      refute log =~ @secret
      refute log =~ "invalid_client"
    end

    test "a transport failure logs its reason, not the secret" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      log = capture_info(fn -> Cognito.request_token() end)

      assert log =~ "econnrefused"
      refute log =~ @secret
    end

    test "an undecodable body is not quoted into the log or the error" do
      respond(200, ~s({"access_token": "#{@token}", broken))

      log =
        capture_info(fn ->
          assert {:error, %Error{} = error} = Cognito.request_token()
          refute inspect(error) =~ @token
          refute inspect(error) =~ @secret
        end)

      refute log =~ @token
    end

    test "no error carries the secret or the token" do
      for {status, body} <- [
            {400, ~s({"error": "#{@secret}"})},
            {401, @token},
            {500, @secret},
            {200, ~s({"access_token": "#{@token}"})}
          ] do
        respond(status, body)
        assert {:error, %Error{} = error} = Cognito.request_token()
        refute inspect(error) =~ @secret
        refute inspect(error) =~ @token
      end
    end
  end

  describe "health_check/0" do
    test "GETs the pool's public JWKS document, unauthenticated, and never asks for a token" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:request, conn.method, conn.host, conn.request_path, conn.req_headers})
        Plug.Conn.resp(conn, 200, ~s({"keys": []}))
      end)

      assert Cognito.health_check() == :ok

      assert_received {:request, "GET", "cognito-idp.us-east-1.amazonaws.com",
                       "/us-east-1_AbC123/.well-known/jwks.json", headers}

      refute List.keymember?(headers, "authorization", 0)
      refute_received {:request, _method, _host, "/oauth2/token", _headers}
    end

    test "any status below 500 means Cognito answered" do
      for status <- [200, 403, 404] do
        respond(status, "{}")
        assert Cognito.health_check() == :ok
      end
    end

    test "a 5xx is :unavailable" do
      respond(503, "{}")

      assert {:error, %Error{kind: :unavailable, details: %{status: 503}}} =
               Cognito.health_check()
    end

    test "a transport failure is :unavailable" do
      stub(&Req.Test.transport_error(&1, :econnrefused))

      assert {:error, %Error{kind: :unavailable}} = Cognito.health_check()
    end

    test "is not affected by the client credentials" do
      configure(client_id: nil, client_secret: nil, scope: nil)
      respond(200, "{}")

      assert Cognito.health_check() == :ok
    end

    test "missing or malformed region and pool id are :not_configured with no request" do
      stub(fn _conn -> flunk("no request should be attempted") end)

      for overrides <- [
            [region: nil],
            [user_pool_id: nil],
            [region: "us-east-1.evil.example/x"],
            [user_pool_id: "../other"]
          ] do
        configure(overrides)
        assert {:error, %Error{kind: :not_configured}} = Cognito.health_check()
      end
    end
  end
end
