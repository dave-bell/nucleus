defmodule Nucleus.Secrets.PathTest do
  use ExUnit.Case, async: false

  alias Nucleus.Secrets.Path

  setup do
    original = Application.get_env(:nucleus, Path)

    Application.put_env(:nucleus, Path, cluster_name: "acme", deployment_name: "main")

    on_exit(fn ->
      if original, do: Application.put_env(:nucleus, Path, original)
    end)

    :ok
  end

  describe "build/2" do
    @cases [
      {"prod", "DATABASE_URL", "/acme/deployments/main/faas/functions/prod/DATABASE_URL"},
      {"shared", "GLOBAL_SALT", "/acme/deployments/main/faas/functions/shared/GLOBAL_SALT"},
      {"staging", "api-key", "/acme/deployments/main/faas/functions/staging/api-key"}
    ]

    for {environment, key, expected} <- @cases do
      @tag :unit
      test "builds #{inspect(expected)} for #{inspect({environment, key})}" do
        assert Path.build(unquote(environment), unquote(key)) == unquote(expected)
      end
    end

    @tag :unit
    test "always starts with / and contains no //" do
      for {environment, key, _expected} <- @cases do
        path = Path.build(environment, key)
        assert String.starts_with?(path, "/")
        refute String.contains?(path, "//")
      end
    end

    @tag :unit
    test "reads CLUSTER_NAME/DEPLOYMENT_NAME from config on every call" do
      Application.put_env(:nucleus, Path, cluster_name: "other", deployment_name: "second")

      assert Path.build("prod", "key") == "/other/deployments/second/faas/functions/prod/key"
    end

    @tag :unit
    test "raises when CLUSTER_NAME is unconfigured" do
      Application.put_env(:nucleus, Path, cluster_name: nil, deployment_name: "main")

      assert_raise RuntimeError, ~r/CLUSTER_NAME/, fn -> Path.build("prod", "key") end
    end

    @tag :unit
    test "raises when DEPLOYMENT_NAME is unconfigured" do
      Application.put_env(:nucleus, Path, cluster_name: "acme", deployment_name: nil)

      assert_raise RuntimeError, ~r/DEPLOYMENT_NAME/, fn -> Path.build("prod", "key") end
    end

    @tag :unit
    test "assumes pre-validated input — the ordering contract is documented, not enforced here" do
      # `build/2` is not a sanitiser; SEC-S1/SEC-S6 validate before this is
      # called. This test exists so nobody mistakes the absence of validation
      # here for an oversight — see the @moduledoc.
      assert Path.build("../etc", "passwd") ==
               "/acme/deployments/main/faas/functions/../etc/passwd"
    end
  end

  describe "prefix/1" do
    @tag :unit
    test "with an environment appends it to the faas/functions prefix" do
      assert Path.prefix("prod") == "/acme/deployments/main/faas/functions/prod"
    end

    @tag :unit
    test "with nil is the bucket-spanning prefix, one level up" do
      assert Path.prefix(nil) == "/acme/deployments/main/faas/functions"
    end
  end
end
