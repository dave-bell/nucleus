defmodule Nucleus.TenantApi.ContractTest do
  @moduledoc """
  The same assertions against every implementation of the boundary.

  `Local` always runs. `Http` runs only when `TEST_TENANT_API_BASE_URL` names a
  real tenant API — it is tagged `:external` and excluded by default in
  `test_helper.exs`, so a fresh clone with no credentials still goes green.

      TEST_TENANT_API_BASE_URL=https://tenant.example.com mix test --include external

  """
  use ExUnit.Case, async: false

  alias Nucleus.TenantApi.Http
  alias Nucleus.TenantApi.Local
  alias NucleusTest.TenantApiContract, as: Contract

  describe "Nucleus.TenantApi.Local" do
    test "returns a list of environments" do
      Contract.assert_lists_environments(Local)
    end

    test "every element is a fully-formed Environment" do
      Contract.assert_element_shape(Local)
    end

    test "optional strings are nil or non-blank, never an empty string" do
      Contract.assert_one_absence_case(Local)
    end

    test "health_check/0 returns :ok" do
      Contract.assert_health_check(Local)
    end
  end

  describe "Nucleus.TenantApi.Http" do
    @describetag :external

    setup do
      base_url =
        System.get_env("TEST_TENANT_API_BASE_URL") ||
          flunk("TEST_TENANT_API_BASE_URL must be set to run the external contract tests")

      original = Application.get_env(:nucleus, Http)

      Application.put_env(:nucleus, Http,
        base_url: base_url,
        connect_timeout_ms: 5_000,
        receive_timeout_ms: 10_000
      )

      on_exit(fn -> Application.put_env(:nucleus, Http, original) end)
      :ok
    end

    test "returns a list of environments" do
      Contract.assert_lists_environments(Http)
    end

    test "every element is a fully-formed Environment" do
      Contract.assert_element_shape(Http)
    end

    test "optional strings are nil or non-blank, never an empty string" do
      Contract.assert_one_absence_case(Http)
    end

    test "health_check/0 returns :ok" do
      Contract.assert_health_check(Http)
    end
  end
end
