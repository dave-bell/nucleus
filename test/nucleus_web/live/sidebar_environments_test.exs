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
end
