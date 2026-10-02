defmodule Nucleus.TenantApiTest do
  # Swaps the configured implementation, which is application-global.
  use ExUnit.Case, async: false

  alias Nucleus.Backend
  alias Nucleus.Backend.Error
  alias Nucleus.TenantApi
  alias Nucleus.TenantApi.ServiceToken

  defmodule RecordingApi do
    @moduledoc false
    # A tenant API that reports the token it was handed, and answers as told.
    @behaviour Nucleus.TenantApi

    @impl true
    def list_environments(token) do
      send(Application.fetch_env!(:nucleus, :tenant_api_test_pid), {:called_with, token})
      Application.get_env(:nucleus, :tenant_api_test_answer, {:ok, []})
    end

    @impl true
    def health_check, do: :ok
  end

  defmodule ScriptedIssuer do
    @moduledoc false
    # A `:service_token` driver that hands out "tok-1", "tok-2", ... and can be
    # told to fail. Runs in the cache's fetch task, hence the Agent.
    @behaviour Nucleus.TenantApi.ServiceToken

    @impl true
    def request_token do
      pid = Application.fetch_env!(:nucleus, :tenant_api_test_pid)
      n = Agent.get_and_update(ScriptedIssuer.Counter, fn n -> {n + 1, n + 1} end)
      send(pid, {:token_requested, n})

      case Application.get_env(:nucleus, :tenant_api_test_issuer_error) do
        nil -> {:ok, %{token: "tok-#{n}", expires_in: 3_600}}
        %Error{} = error -> {:error, error}
      end
    end

    @impl true
    def health_check, do: :ok
  end

  setup do
    original = Application.get_env(:nucleus, :backends)
    Application.put_env(:nucleus, :tenant_api_test_pid, self())
    ServiceToken.clear()

    on_exit(fn ->
      Application.put_env(:nucleus, :backends, original)
      Application.delete_env(:nucleus, :tenant_api_test_pid)
      Application.delete_env(:nucleus, :tenant_api_test_answer)
      Application.delete_env(:nucleus, :tenant_api_test_issuer_error)
      ServiceToken.clear()
    end)

    :ok
  end

  defp use_backend(module), do: use_backend(:tenant_api, module)

  defp use_backend(boundary, module) do
    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(Application.get_env(:nucleus, :backends, []), boundary, module)
    )
  end

  describe "the boundary now resolves" do
    test "impl_for(:tenant_api) no longer raises" do
      # `adr/0002` recorded that this raised until EN-3 landed. It is the one
      # externally visible thing this ticket had to change about EN-2's scaffolding.
      assert Backend.impl_for(:tenant_api) == Nucleus.TenantApi.Local
    end

    test "both registered implementations exist and implement the behaviour" do
      for mode <- [:real, :local] do
        module = Backend.impl_for_mode!(:tenant_api, mode)

        assert Code.ensure_loaded?(module)
        assert TenantApi in module.module_info(:attributes)[:behaviour]
      end
    end
  end

  describe "dispatch" do
    test "list_environments/0 goes to the configured implementation" do
      use_backend(Nucleus.TenantApi.Local)
      assert {:ok, environments} = TenantApi.list_environments()
      assert environments != []
    end

    test "health_check/0 goes to the configured implementation" do
      use_backend(Nucleus.TenantApi.Local)
      assert TenantApi.health_check() == :ok
    end

    test "resolves on every call, so a config change takes effect immediately" do
      # Resolution is per call rather than at compile time so that runtime.exs and
      # a test override both take effect. Two implementations that fail differently
      # is the cheapest way to prove the switch actually moved.
      use_backend(Nucleus.TenantApi.Local)
      assert {:ok, _environments} = TenantApi.list_environments()

      original_http = Application.get_env(:nucleus, Nucleus.TenantApi.Http)
      on_exit(fn -> Application.put_env(:nucleus, Nucleus.TenantApi.Http, original_http) end)
      Application.put_env(:nucleus, Nucleus.TenantApi.Http, base_url: nil)
      use_backend(Nucleus.TenantApi.Http)

      assert {:error, %Error{kind: :not_configured}} = TenantApi.list_environments()
    end
  end

  describe "the service credential" do
    test "list_environments/0 takes no argument from the caller" do
      refute function_exported?(TenantApi, :list_environments, 1)
      assert function_exported?(TenantApi, :list_environments, 0)
    end

    test "fetches a token from the :service_token boundary and hands it down" do
      use_backend(RecordingApi)

      assert {:ok, []} = TenantApi.list_environments()

      assert_received {:called_with, token}
      assert token == Nucleus.TenantApi.ServiceToken.Local.token()
    end

    test "reuses a cached token across calls" do
      use_backend(RecordingApi)
      use_backend(:service_token, ScriptedIssuer)
      start_counter()

      assert {:ok, []} = TenantApi.list_environments()
      assert {:ok, []} = TenantApi.list_environments()

      assert_received {:called_with, "tok-1"}
      assert_received {:called_with, "tok-1"}
      assert_received {:token_requested, 1}
      refute_received {:token_requested, 2}
    end

    test "a token that cannot be fetched is returned, and the tenant API is never called" do
      error = Error.new(:unavailable, :service_token, "the issuer is down")
      Application.put_env(:nucleus, :tenant_api_test_issuer_error, error)
      start_counter()
      use_backend(RecordingApi)
      use_backend(:service_token, ScriptedIssuer)

      assert TenantApi.list_environments() == {:error, error}
      refute_received {:called_with, _token}
    end

    test "a tenant API :auth_expired invalidates the token, so the next call fetches a fresh one" do
      start_counter()
      use_backend(RecordingApi)
      use_backend(:service_token, ScriptedIssuer)

      rejected = Error.new(:auth_expired, :tenant_api, "the tenant API rejected our credentials")
      Application.put_env(:nucleus, :tenant_api_test_answer, {:error, rejected})

      assert TenantApi.list_environments() == {:error, rejected}
      assert_received {:called_with, "tok-1"}

      Application.put_env(:nucleus, :tenant_api_test_answer, {:ok, []})

      assert {:ok, []} = TenantApi.list_environments()
      assert_received {:called_with, "tok-2"}
    end

    test "other errors leave the cached token alone" do
      start_counter()
      use_backend(RecordingApi)
      use_backend(:service_token, ScriptedIssuer)

      down = Error.new(:unavailable, :tenant_api, "the tenant API is down")
      Application.put_env(:nucleus, :tenant_api_test_answer, {:error, down})

      assert TenantApi.list_environments() == {:error, down}
      assert TenantApi.list_environments() == {:error, down}

      assert_received {:called_with, "tok-1"}
      assert_received {:called_with, "tok-1"}
      refute_received {:token_requested, 2}
    end

    test "health_check/0 fetches no token" do
      start_counter()
      use_backend(Nucleus.TenantApi.Local)
      use_backend(:service_token, ScriptedIssuer)

      assert TenantApi.health_check() == :ok
      refute_received {:token_requested, _n}
    end

    defp start_counter do
      start_supervised!(%{
        id: ScriptedIssuer.Counter,
        start: {Agent, :start_link, [fn -> 0 end, [name: ScriptedIssuer.Counter]]}
      })
    end
  end

  describe "over HTTP" do
    @stub __MODULE__

    setup do
      original = Application.get_env(:nucleus, Nucleus.TenantApi.Http)

      Application.put_env(:nucleus, Nucleus.TenantApi.Http,
        base_url: "https://tenant.example.com",
        plug: {Req.Test, @stub}
      )

      on_exit(fn -> Application.put_env(:nucleus, Nucleus.TenantApi.Http, original) end)

      start_counter()
      use_backend(Nucleus.TenantApi.Http)
      use_backend(:service_token, ScriptedIssuer)
      :ok
    end

    defp answer(status) do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        send(test_pid, {:tenant_api_request, Plug.Conn.get_req_header(conn, "authorization")})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, ~s([{"shortName": "prod"}]))
      end)
    end

    test "sends Nucleus's service token as a bearer credential" do
      answer(200)

      assert {:ok, [%{short_name: "prod"}]} = TenantApi.list_environments()
      assert_received {:tenant_api_request, ["Bearer tok-1"]}
    end

    for status <- [401, 403] do
      test "a #{status} makes one request, returns :auth_expired, and the next call refetches" do
        answer(unquote(status))

        assert {:error, %Error{kind: :auth_expired}} = TenantApi.list_environments()

        # Exactly one request: no retry here. The automatic retry is SEC-S7's.
        assert_received {:tenant_api_request, ["Bearer tok-1"]}
        refute_received {:tenant_api_request, _authorization}
        assert_received {:token_requested, 1}

        answer(200)

        assert {:ok, [%{short_name: "prod"}]} = TenantApi.list_environments()
        assert_received {:token_requested, 2}
        assert_received {:tenant_api_request, ["Bearer tok-2"]}
      end
    end

    test "a token that cannot be fetched means no request to the tenant API" do
      error = Error.new(:auth_expired, :service_token, "cognito rejected the client")
      Application.put_env(:nucleus, :tenant_api_test_issuer_error, error)
      answer(200)

      assert TenantApi.list_environments() == {:error, error}
      refute_received {:tenant_api_request, _authorization}
    end
  end

  describe "boundary/0" do
    test "names the boundary the errors are tagged with" do
      assert TenantApi.boundary() == :tenant_api
      assert TenantApi.boundary() in Backend.boundaries()
    end
  end
end
