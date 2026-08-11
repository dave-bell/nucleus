defmodule Nucleus.TenantApi.HttpTest do
  # Configuration is application-global, so these cannot run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Several cases deliberately provoke a transport failure, which logs a warning.
  # Captured so the suite's output stays readable; the logging assertions below
  # still read what was captured.
  @moduletag :capture_log

  alias Nucleus.Backend.Error
  alias Nucleus.TenantApi.Http

  @stub __MODULE__

  setup do
    original = Application.get_env(:nucleus, Http)
    on_exit(fn -> Application.put_env(:nucleus, Http, original) end)
    :ok
  end

  defp configure(overrides \\ []) do
    Application.put_env(
      :nucleus,
      Http,
      Keyword.merge(
        [base_url: "https://tenant.example.com", plug: {Req.Test, @stub}],
        overrides
      )
    )
  end

  defp stub(fun), do: Req.Test.stub(@stub, fun)

  defp respond(status, body, content_type \\ "application/json") do
    stub(fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.resp(status, body)
    end)
  end

  defp respond_json(status, data), do: respond(status, Jason.encode!(data))

  defp environment(attrs \\ %{}), do: Map.merge(%{"shortName" => "prod"}, attrs)

  # The suite runs at :warning, which filters an :info message before any capture
  # handler sees it. Successful calls log at :info — the level a routine, expected
  # event belongs at — so the level has to come down for the duration.
  defp capture_info(fun) do
    original = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original) end)

    capture_log(fun)
  end

  describe "the request" do
    test "hits the hardcoded /environment path on the configured base URL" do
      configure()

      stub(fn conn ->
        assert conn.request_path == "/environment"
        assert conn.host == "tenant.example.com"
        assert conn.method == "GET"
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = Http.list_environments(nil)
    end

    test "preserves a path prefix on the base URL and tolerates a trailing slash" do
      configure(base_url: "https://tenant.example.com/api/v2/")

      stub(fn conn ->
        assert conn.request_path == "/api/v2/environment"
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = Http.list_environments(nil)
    end

    test "sends no Authorization header for a nil token" do
      configure()

      stub(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = Http.list_environments(nil)
    end

    test "sends a bearer token when there is one" do
      configure()

      stub(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer tok_abc123"]
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = Http.list_environments("tok_abc123")
    end

    test "sends no Authorization header for a blank token, rather than an empty bearer" do
      configure()

      stub(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = Http.list_environments("")
    end
  end

  describe "translation" do
    test "camelCase becomes snake_case, including isArchived -> archived?" do
      configure()

      respond_json(200, [
        %{
          "shortName" => "legacy-qa",
          "label" => "Legacy QA",
          "iri" => "https://tenant.example.com/environment/legacy-qa",
          "accentColor" => "#4b5563",
          "categories" => ["Deprecated"],
          "isArchived" => true,
          "description" => "Retired."
        }
      ])

      assert {:ok, [environment]} = Http.list_environments(nil)
      assert environment.short_name == "legacy-qa"
      assert environment.accent_color == "#4b5563"
      assert environment.archived? == true
    end

    test "an empty description normalises to nil" do
      configure()
      respond_json(200, [environment(%{"description" => ""})])

      assert {:ok, [%{description: nil}]} = Http.list_environments(nil)
    end

    test "absent or null categories normalise to []" do
      configure()
      respond_json(200, [environment(), environment(%{"categories" => nil})])

      assert {:ok, [%{categories: []}, %{categories: []}]} = Http.list_environments(nil)
    end

    test "archived environments are returned, not filtered" do
      configure()

      respond_json(200, [
        environment(%{"shortName" => "prod"}),
        environment(%{"shortName" => "legacy-qa", "isArchived" => true})
      ])

      assert {:ok, environments} = Http.list_environments(nil)
      assert Enum.map(environments, & &1.short_name) == ["prod", "legacy-qa"]
    end
  end

  describe "a bad shortName fails the whole call" do
    for {label, value} <- [{"missing", :absent}, {"nil", nil}, {"blank", ""}] do
      test "#{label} shortName yields :unavailable and no partial list" do
        configure()

        bad =
          case unquote(Macro.escape(value)) do
            :absent -> %{"label" => "No short name"}
            other -> %{"shortName" => other}
          end

        respond_json(200, [environment(%{"shortName" => "prod"}), bad])

        assert {:error, %Error{kind: :unavailable, details: details}} =
                 Http.list_environments(nil)

        assert details.reason == :missing_short_name
      end
    end
  end

  describe "status mapping" do
    for status <- [400, 404, 429, 500, 502, 503, 418, 301] do
      test "#{status} maps to :unavailable" do
        configure()
        respond(unquote(status), "{}")

        assert {:error, %Error{kind: :unavailable, boundary: :tenant_api, details: details}} =
                 Http.list_environments(nil)

        assert details.status == unquote(status)
      end
    end

    for status <- [401, 403] do
      test "#{status} maps to :auth_expired" do
        configure()
        respond(unquote(status), "{}")

        assert {:error, %Error{kind: :auth_expired, details: %{status: unquote(status)}}} =
                 Http.list_environments(nil)
      end
    end

    test "a transport error maps to :unavailable" do
      configure()
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Error{kind: :unavailable, details: details}} = Http.list_environments(nil)
      assert details.reason =~ "econnrefused"
    end

    test "an undecodable body maps to :unavailable" do
      configure()
      respond(200, "{not json")

      assert {:error, %Error{kind: :unavailable, message: message}} = Http.list_environments(nil)
      assert message =~ "not JSON"
    end

    test "a decodable body of the wrong shape maps to :unavailable" do
      configure()
      respond_json(200, %{"environments" => [environment()]})

      assert {:error, %Error{kind: :unavailable, message: message}} = Http.list_environments(nil)
      assert message =~ "unexpected shape"
    end

    test "a redirect is not followed — the token never reaches the redirect target" do
      configure()

      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://attacker.example.com/environment")
        |> Plug.Conn.resp(302, "")
      end)

      assert {:error, %Error{kind: :unavailable, details: %{status: 302}}} =
               Http.list_environments("tok_abc123")
    end
  end

  describe "an unusable base URL" do
    for {label, base_url} <- [
          {"unset", nil},
          {"blank", "   "},
          {"not a URL", "tenant.example.com"},
          {"a non-http scheme", "file:///etc/passwd"},
          {"missing a host", "https://"}
        ] do
      test "#{label} yields :not_configured and attempts no request" do
        configure(base_url: unquote(base_url))

        test_pid = self()

        stub(fn conn ->
          send(test_pid, :request_attempted)
          Req.Test.json(conn, [])
        end)

        assert {:error, %Error{kind: :not_configured, details: %{variable: var}}} =
                 Http.list_environments(nil)

        assert var == "TENANT_API_BASE_URL"
        refute_received :request_attempted
      end
    end
  end

  describe "health_check/0" do
    test "is :ok on 200" do
      configure()
      respond_json(200, [environment()])

      assert Http.health_check() == :ok
    end

    for status <- [400, 401, 403, 404, 429] do
      test "is :ok on #{status} — reachability, not permission" do
        # A 401 means the service answered. Treating it as unhealthy would make
        # every health check start failing the moment EN-6 makes anonymous calls
        # unauthorised.
        configure()
        respond(unquote(status), "{}")

        assert Http.health_check() == :ok
      end
    end

    for status <- [500, 502, 503] do
      test "is :unavailable on #{status}" do
        configure()
        respond(unquote(status), "{}")

        assert {:error, %Error{kind: :unavailable}} = Http.health_check()
      end
    end

    test "is :unavailable on a transport error" do
      configure()
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Error{kind: :unavailable}} = Http.health_check()
    end

    test "is :not_configured with no base URL" do
      configure(base_url: nil)

      assert {:error, %Error{kind: :not_configured}} = Http.health_check()
    end

    test "is :ok on a malformed body — a bad list is not an unreachable dependency" do
      configure()
      respond(200, "{not json")

      assert Http.health_check() == :ok
    end
  end

  describe "logging" do
    test "records the status and a request id, and never the token" do
      # Deliberately two-sided. Asserting only that the token is absent passes
      # vacuously when the code logs nothing at all, which would leave the real
      # requirement — that a call is traceable without its credentials — untested.
      configure()
      respond_json(200, [environment()])

      log = capture_info(fn -> Http.list_environments("tok_supersecret") end)

      assert log =~ "-> 200"
      assert log =~ ~r/request_id=[0-9a-f]{16}/
      refute log =~ "tok_supersecret"
      refute log =~ "Bearer"
    end

    test "never logs the response body" do
      configure()
      respond_json(200, [environment(%{"description" => "leak-me-please"})])

      log = capture_info(fn -> Http.list_environments(nil) end)

      assert log =~ "-> 200"
      refute log =~ "leak-me-please"
    end

    test "records the reason on a transport failure, without the token" do
      configure()
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      log = capture_info(fn -> Http.list_environments("tok_supersecret") end)

      assert log =~ "econnrefused"
      assert log =~ ~r/request_id=[0-9a-f]{16}/
      refute log =~ "tok_supersecret"
    end

    test "does not log an undecodable body when it reports one" do
      configure()
      respond(200, ~s({"secret": "leak-me-please"))

      log = capture_info(fn -> Http.list_environments(nil) end)

      refute log =~ "leak-me-please"
    end
  end

  describe "timeouts" do
    test "are configured independently, and fall back to sane defaults" do
      configure(connect_timeout_ms: nil, receive_timeout_ms: nil)
      respond_json(200, [])

      # The defaults must be usable, not merely present: a nil reaching Req's
      # `receive_timeout` would wait forever and hang a LiveView mount.
      assert {:ok, []} = Http.list_environments(nil)
    end
  end
end
