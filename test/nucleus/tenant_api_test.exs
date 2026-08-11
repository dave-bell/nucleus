defmodule Nucleus.TenantApiTest do
  # Swaps the configured implementation, which is application-global.
  use ExUnit.Case, async: false

  alias Nucleus.Backend
  alias Nucleus.Backend.Error
  alias Nucleus.TenantApi

  setup do
    original = Application.get_env(:nucleus, :backends)
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)
    :ok
  end

  defp use_backend(module) do
    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(Application.get_env(:nucleus, :backends, []), :tenant_api, module)
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
    test "list_environments/1 goes to the configured implementation" do
      use_backend(Nucleus.TenantApi.Local)
      assert {:ok, environments} = TenantApi.list_environments(nil)
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
      assert {:ok, _environments} = TenantApi.list_environments(nil)

      original_http = Application.get_env(:nucleus, Nucleus.TenantApi.Http)
      on_exit(fn -> Application.put_env(:nucleus, Nucleus.TenantApi.Http, original_http) end)
      Application.put_env(:nucleus, Nucleus.TenantApi.Http, base_url: nil)
      use_backend(Nucleus.TenantApi.Http)

      assert {:error, %Error{kind: :not_configured}} = TenantApi.list_environments(nil)
    end
  end

  describe "the token argument" do
    test "accepts a binary and nil, because auth is deferred to EN-6" do
      use_backend(Nucleus.TenantApi.Local)

      assert {:ok, _} = TenantApi.list_environments(nil)
      assert {:ok, _} = TenantApi.list_environments("tok_abc123")
    end

    test "rejects anything else at the boundary rather than passing it down" do
      use_backend(Nucleus.TenantApi.Local)

      # Built at runtime: the compiler's type checker rejects the literal, since
      # the guard on list_environments/1 declares what it accepts.
      not_a_token = Jason.decode!(~s({"token": "x"}))

      assert_raise FunctionClauseError, fn -> TenantApi.list_environments(not_a_token) end
    end
  end

  describe "boundary/0" do
    test "names the boundary the errors are tagged with" do
      assert TenantApi.boundary() == :tenant_api
      assert TenantApi.boundary() in Backend.boundaries()
    end
  end
end
