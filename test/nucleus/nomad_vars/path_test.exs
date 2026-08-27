defmodule Nucleus.NomadVars.PathTest do
  use ExUnit.Case, async: false

  alias Nucleus.NomadVars.Path
  alias Nucleus.Scope

  setup do
    original = Application.get_env(:nucleus, Scope)
    Application.put_env(:nucleus, Scope, tenant_namespace: "acme")

    on_exit(fn ->
      if original, do: Application.put_env(:nucleus, Scope, original)
    end)

    :ok
  end

  describe "path/0" do
    @tag :unit
    test "builds nomad/jobs/{tenant_namespace}-data_export" do
      assert Path.path() == "nomad/jobs/acme-data_export"
    end

    @tag :unit
    test "reads TENANT_NAMESPACE from config on every call, not at compile time" do
      Application.put_env(:nucleus, Scope, tenant_namespace: "other-tenant")

      assert Path.path() == "nomad/jobs/other-tenant-data_export"
    end
  end

  describe "job_name/0" do
    @tag :unit
    test "is the suffix of path/0" do
      assert Path.job_name() == "acme-data_export"
      assert Path.path() == "nomad/jobs/" <> Path.job_name()
    end

    @tag :unit
    test "reads TENANT_NAMESPACE from config on every call" do
      Application.put_env(:nucleus, Scope, tenant_namespace: "other-tenant")

      assert Path.job_name() == "other-tenant-data_export"
    end
  end
end
