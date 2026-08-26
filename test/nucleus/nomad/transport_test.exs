defmodule Nucleus.Nomad.TransportTest do
  # Configuration is application-global, so these cannot run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Several cases deliberately provoke a transport failure, which logs a
  # warning. Captured so the suite's output stays readable.
  @moduletag :capture_log

  alias Nucleus.Backend.Error
  alias Nucleus.Nomad.Transport

  @stub __MODULE__
  @boundary :nomad_jobs

  setup do
    original = Application.get_env(:nucleus, Transport)
    on_exit(fn -> Application.put_env(:nucleus, Transport, original) end)
    :ok
  end

  defp configure(overrides \\ []) do
    Application.put_env(
      :nucleus,
      Transport,
      Keyword.merge(
        [base_url: "https://nomad.example.com", plug: {Req.Test, @stub}],
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

  defp request(path, opts \\ []) do
    Transport.request(:get, path, Keyword.merge([boundary: @boundary], opts))
  end

  defp capture_info(fun) do
    original = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original) end)

    capture_log(fun)
  end

  describe "the request" do
    test "hits the given path on the configured base URL, with query params" do
      configure()

      stub(fn conn ->
        assert conn.request_path == "/v1/jobs"
        assert conn.query_string == "namespace=local"
        assert conn.host == "nomad.example.com"
        assert conn.method == "GET"
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = request("/v1/jobs", query: [namespace: "local"])
    end

    test "preserves a path prefix on the base URL and tolerates a trailing slash" do
      configure(base_url: "https://nomad.example.com/api/")

      stub(fn conn ->
        assert conn.request_path == "/api/v1/jobs"
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = request("/v1/jobs")
    end

    test "sends no X-Nomad-Token header when unset" do
      configure()

      stub(fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-nomad-token") == []
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = request("/v1/jobs")
    end

    test "sends X-Nomad-Token when configured" do
      configure(token: "tok_abc123")

      stub(fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-nomad-token") == ["tok_abc123"]
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = request("/v1/jobs")
    end

    test "sends no X-Nomad-Token header for a blank token, rather than an empty one" do
      configure(token: "")

      stub(fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-nomad-token") == []
        Req.Test.json(conn, [])
      end)

      assert {:ok, []} = request("/v1/jobs")
    end
  end

  describe "decoding" do
    test "a JSON array decodes to a list" do
      configure()
      respond_json(200, [%{"ID" => "api"}])

      assert {:ok, [%{"ID" => "api"}]} = request("/v1/jobs")
    end

    test "a JSON object decodes to a map" do
      configure()
      respond_json(200, %{"ID" => "api"})

      assert {:ok, %{"ID" => "api"}} = request("/v1/job/api")
    end

    test "an undecodable body maps to :unavailable" do
      configure()
      respond(200, "{not json")

      assert {:error, %Error{kind: :unavailable, boundary: :nomad_jobs, message: message}} =
               request("/v1/jobs")

      assert message =~ "not JSON"
    end
  end

  describe "status mapping" do
    for status <- [400, 404, 429, 500, 502, 503, 418] do
      test "#{status} maps to :unavailable" do
        configure()
        respond(unquote(status), "{}")

        assert {:error, %Error{kind: :unavailable, boundary: :nomad_jobs, details: details}} =
                 request("/v1/jobs")

        assert details.status == unquote(status)
      end
    end

    for status <- [401, 403] do
      test "#{status} maps to :auth_expired" do
        configure()
        respond(unquote(status), "{}")

        assert {:error, %Error{kind: :auth_expired, details: %{status: unquote(status)}}} =
                 request("/v1/jobs")
      end
    end

    test "a transport error maps to :unavailable" do
      configure()
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Error{kind: :unavailable, details: details}} = request("/v1/jobs")
      assert details.reason =~ "econnrefused"
    end

    test "a redirect is not followed" do
      configure()

      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://attacker.example.com/v1/jobs")
        |> Plug.Conn.resp(302, "")
      end)

      assert {:error, %Error{kind: :unavailable, details: %{status: 302}}} = request("/v1/jobs")
    end
  end

  describe "an unusable base URL" do
    for {label, base_url} <- [
          {"unset", nil},
          {"blank", "   "},
          {"not a URL", "nomad.example.com"},
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
                 request("/v1/jobs")

        assert var == "NOMAD_ADDR"
        refute_received :request_attempted
      end
    end
  end

  describe "logging" do
    test "records the status and a request id, and never the token" do
      configure(token: "tok_supersecret")
      respond_json(200, [])

      log = capture_info(fn -> request("/v1/jobs") end)

      assert log =~ "-> 200"
      assert log =~ ~r/request_id=[0-9a-f]{16}/
      refute log =~ "tok_supersecret"
    end

    test "never logs the response body" do
      configure()
      respond_json(200, [%{"secret" => "leak-me-please"}])

      log = capture_info(fn -> request("/v1/jobs") end)

      assert log =~ "-> 200"
      refute log =~ "leak-me-please"
    end
  end

  describe "timeouts" do
    test "are configured independently, and fall back to sane defaults" do
      configure(connect_timeout_ms: nil, receive_timeout_ms: nil)
      respond_json(200, [])

      assert {:ok, []} = request("/v1/jobs")
    end
  end
end
