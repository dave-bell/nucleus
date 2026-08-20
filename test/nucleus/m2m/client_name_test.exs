defmodule Nucleus.M2M.ClientNameTest do
  # Mutates the node-global Nucleus.Scope tenant_namespace config.
  use ExUnit.Case, async: false

  alias Nucleus.M2M.ClientName

  setup do
    original = Application.get_env(:nucleus, Nucleus.Scope, [])
    on_exit(fn -> Application.put_env(:nucleus, Nucleus.Scope, original) end)
    :ok
  end

  defp put_tenant(tenant) do
    Application.put_env(:nucleus, Nucleus.Scope, tenant_namespace: tenant)
  end

  describe "build/2" do
    @tag :unit
    test "produces {tenant}-control-plane-{ticket_id}-{purpose} for the configured tenant" do
      put_tenant("acme")

      assert ClientName.build("OPS-1234", "nightly-sync") ==
               "acme-control-plane-OPS-1234-nightly-sync"
    end

    @tag :unit
    test "reads the tenant at call time, not at compile time" do
      put_tenant("acme")
      assert ClientName.build("OPS-1", "x") == "acme-control-plane-OPS-1-x"

      put_tenant("other")
      assert ClientName.build("OPS-1", "x") == "other-control-plane-OPS-1-x"
    end
  end

  describe "prefix/0" do
    @tag :unit
    test "is {tenant}-control-plane-" do
      put_tenant("acme")
      assert ClientName.prefix() == "acme-control-plane-"
    end
  end

  describe "in_tenant?/1" do
    @tag :unit
    test "true for a name built by build/2" do
      put_tenant("acme")
      name = ClientName.build("OPS-1234", "nightly-sync")
      assert ClientName.in_tenant?(name)
    end

    @tag :unit
    test "false for another tenant's name" do
      put_tenant("acme")
      refute ClientName.in_tenant?("other-tenant-control-plane-OPS-1-x")
    end

    @tag :unit
    test "false for an empty string" do
      put_tenant("acme")
      refute ClientName.in_tenant?("")
    end

    @tag :unit
    test "is not fooled by the prefix appearing later in the string" do
      put_tenant("acme")
      refute ClientName.in_tenant?("x-acme-control-plane-OPS-1-x")
    end
  end
end
