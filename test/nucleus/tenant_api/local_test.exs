defmodule Nucleus.TenantApi.LocalTest do
  # Fault injection is read from the OS environment, which is global to the node.
  use ExUnit.Case, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Seed
  alias Nucleus.TenantApi.Environment
  alias Nucleus.TenantApi.Local

  setup do
    # The seed owner is mutable and outlives any one test.
    on_exit(&Seed.reset/0)
    :ok
  end

  defp force_error(kind) do
    System.put_env("LOCAL_FORCE_ERROR", kind)
    on_exit(fn -> System.delete_env("LOCAL_FORCE_ERROR") end)
  end

  defp environment!(short_name) do
    assert {:ok, environments} = Local.list_environments(nil)
    assert environment = Enum.find(environments, &(&1.short_name == short_name))
    environment
  end

  describe "the seeded fixtures" do
    test "all five are present, so downstream tickets need not invent their own" do
      assert {:ok, environments} = Local.list_environments(nil)

      assert Enum.map(environments, & &1.short_name) |> Enum.sort() ==
               ["dev", "legacy-qa", "prod", "sandbox", "staging"]
    end

    test "prod has multiple categories and a description" do
      environment = environment!("prod")

      assert length(environment.categories) > 1
      assert is_binary(environment.description)
    end

    test "staging has a single category" do
      assert length(environment!("staging").categories) == 1
    end

    test "dev has no categories — the ENV-A02/NAV-A04 grouping fallback" do
      assert environment!("dev").categories == []
    end

    test "sandbox has description: nil, not an empty string — the ENV-A02 omission case" do
      assert environment!("sandbox").description == nil
    end

    test "legacy-qa is archived" do
      assert environment!("legacy-qa").archived? == true
    end
  end

  describe "archived environments" do
    test "are returned, not filtered — the ENV-A06 regression guard" do
      # `NAV-A04` hides archived environments from the sidebar and `ENV-A06`
      # requires they stay reachable by direct URL. Filtering here would make the
      # second unimplementable, so this is deliberately asserted, not incidental.
      assert {:ok, environments} = Local.list_environments(nil)

      assert Enum.any?(environments, &(&1.short_name == "legacy-qa" and &1.archived?))
    end
  end

  describe "the shared translation" do
    test "every element is a fully-formed Environment struct" do
      assert {:ok, environments} = Local.list_environments(nil)

      for environment <- environments do
        assert %Environment{} = environment
        assert is_binary(environment.short_name) and environment.short_name != ""
        assert is_list(environment.categories)
        assert is_boolean(environment.archived?)
      end
    end
  end

  describe "fault injection" do
    test "LOCAL_FORCE_ERROR=unavailable is the hook SEC-S1 uses for fail-closed" do
      force_error("unavailable")

      assert {:error, %Error{kind: :unavailable, boundary: :tenant_api}} =
               Local.list_environments(nil)
    end

    test "LOCAL_FORCE_ERROR=auth_expired surfaces as :auth_expired" do
      force_error("auth_expired")

      assert {:error, %Error{kind: :auth_expired}} = Local.list_environments(nil)
    end

    test "applies to health_check/0 as well" do
      force_error("unavailable")

      assert {:error, %Error{kind: :unavailable}} = Local.health_check()
    end

    test "an unparseable value raises rather than passing silently" do
      force_error("teapot")

      assert_raise ArgumentError, fn -> Local.list_environments(nil) end
    end
  end

  describe "health_check/0" do
    test "is :ok when the seed is readable" do
      assert Local.health_check() == :ok
    end
  end

  describe "a broken seed section" do
    test "reads as :not_configured, not :unavailable — a bad file is not an unreachable API" do
      Seed.write(:tenant_api, %{"environments" => [%{"label" => "no short name"}]})

      assert {:error, %Error{kind: :not_configured, details: %{reason: :missing_short_name}}} =
               Local.list_environments(nil)
    end

    test "reads as :not_configured when the section is absent" do
      Seed.write(:tenant_api, nil)

      assert {:error, %Error{kind: :not_configured}} = Local.list_environments(nil)
    end

    test "reads as :not_configured when the section has no environments list" do
      Seed.write(:tenant_api, %{})

      assert {:error, %Error{kind: :not_configured}} = Local.list_environments(nil)
    end

    test "fails health_check/0" do
      Seed.write(:tenant_api, %{})

      assert {:error, %Error{kind: :not_configured}} = Local.health_check()
    end
  end
end
