defmodule NucleusWeb.SidebarEnvironmentsTest do
  use ExUnit.Case, async: true

  alias Nucleus.TenantApi.Environment
  alias NucleusWeb.SidebarEnvironments

  doctest SidebarEnvironments

  defp env(short_name, categories, archived? \\ false) do
    %Environment{short_name: short_name, categories: categories, archived?: archived?}
  end

  @tag action: "NAV-A04"
  test "an environment in two categories appears in both groups' environment lists" do
    prod = env("prod", ["Customer Facing", "Regulated"])

    groups = SidebarEnvironments.group([prod])

    assert %{category: "Customer Facing", environments: [^prod]} =
             Enum.find(groups, &(&1.category == "Customer Facing"))

    assert %{category: "Regulated", environments: [^prod]} =
             Enum.find(groups, &(&1.category == "Regulated"))
  end

  @tag action: "NAV-A04"
  test "an uncategorized environment lands in its own group, sorted after every named category" do
    dev = env("dev", [])
    sandbox = env("sandbox", ["Experimental"])

    groups = SidebarEnvironments.group([dev, sandbox])

    assert Enum.map(groups, & &1.category) == ["Experimental", :uncategorized]
  end

  @tag action: "NAV-A04"
  test "each group's count matches its environment list's length" do
    prod = env("prod", ["Customer Facing", "Regulated"])
    staging = env("staging", ["Regulated"])

    groups = SidebarEnvironments.group([prod, staging])

    for group <- groups do
      assert group.count == length(group.environments)
    end

    assert Enum.find(groups, &(&1.category == "Regulated")).count == 2
    assert Enum.find(groups, &(&1.category == "Customer Facing")).count == 1
  end

  @tag action: "NAV-A04"
  test "an archived environment appears in no group, even if categorized" do
    legacy_qa = env("legacy-qa", ["Deprecated"], true)
    staging = env("staging", ["Pre-Production"])

    groups = SidebarEnvironments.group([legacy_qa, staging])

    assert Enum.map(groups, & &1.category) == ["Pre-Production"]
    refute Enum.any?(groups, &(&1.category == "Deprecated"))
  end

  @tag action: "NAV-A04"
  test "group order is stable and case-insensitively alphabetical, uncategorized last, across repeated calls" do
    environments = [
      env("prod", ["regulated", "Customer Facing"]),
      env("staging", ["Pre-Production"]),
      env("dev", []),
      env("sandbox", ["experimental"])
    ]

    expected = ["Customer Facing", "experimental", "Pre-Production", "regulated", :uncategorized]

    for _ <- 1..3 do
      assert SidebarEnvironments.group(environments) |> Enum.map(& &1.category) == expected
    end
  end

  @tag action: "NAV-A04"
  test "zero environments in, zero groups out" do
    assert SidebarEnvironments.group([]) == []
  end

  describe "with_slugs/1" do
    test "a category with no colliding sibling keeps its plain slug" do
      groups = SidebarEnvironments.group([env("prod", ["Pre-Production"])])

      assert [%{group: %{category: "Pre-Production"}, slug: "pre-production"}] =
               SidebarEnvironments.with_slugs(groups)
    end

    test "categories that differ only by case or punctuation get disambiguated, later ones suffixed" do
      # group/1 keeps these as three distinct groups (it keys on the exact
      # string) — all three would otherwise render with the same DOM id and
      # share expand/collapse state, since slug/1 alone collapses all three
      # to "prod-east".
      groups = [
        %{category: "Prod East", environments: [], count: 0},
        %{category: "Prod-East", environments: [], count: 0},
        %{category: "PROD_EAST", environments: [], count: 0}
      ]

      slugs = SidebarEnvironments.with_slugs(groups) |> Enum.map(& &1.slug)

      assert slugs == ["prod-east", "prod-east-2", "prod-east-3"]
      assert length(Enum.uniq(slugs)) == 3
    end

    test "disambiguation is scoped to :uncategorized's own base slug too" do
      groups = [
        %{category: :uncategorized, environments: [], count: 0},
        %{category: "uncategorized", environments: [], count: 0}
      ]

      slugs = SidebarEnvironments.with_slugs(groups) |> Enum.map(& &1.slug)

      assert slugs == ["uncategorized", "uncategorized-2"]
    end

    test "each slugged entry still carries its original group unchanged" do
      prod = env("prod", ["Regulated"])
      groups = SidebarEnvironments.group([prod])

      assert [%{group: %{category: "Regulated", environments: [^prod], count: 1}}] =
               SidebarEnvironments.with_slugs(groups)
    end
  end
end
