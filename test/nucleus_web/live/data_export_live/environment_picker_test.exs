defmodule NucleusWeb.DataExportLive.EnvironmentPickerTest do
  use ExUnit.Case, async: true

  alias Nucleus.TenantApi.Environment
  alias NucleusWeb.DataExportLive.EnvironmentPicker

  defp env(short_name, label \\ nil) do
    %Environment{short_name: short_name, label: label}
  end

  describe "DEX-A07 — pre-selection at construction" do
    @tag action: "DEX-A07"
    test "new/2 pre-selects exactly the given selected_names, others unselected" do
      prod = env("prod", "Production")
      staging = env("staging", "Staging")
      dev = env("dev", "Development")

      picker = EnvironmentPicker.new([prod, staging, dev], ["prod", "dev"])

      assert Enum.sort(EnvironmentPicker.selected_names(picker)) == ["dev", "prod"]

      assert Enum.map(EnvironmentPicker.selected_matches(picker), & &1.short_name) |> Enum.sort() ==
               ["dev", "prod"]

      assert Enum.map(EnvironmentPicker.available_matches(picker), & &1.short_name) ==
               ["staging"]
    end

    @tag action: "DEX-A07"
    test "new/2 with no selected_names leaves every environment available" do
      prod = env("prod")
      staging = env("staging")

      picker = EnvironmentPicker.new([prod, staging], [])

      assert EnvironmentPicker.selected_names(picker) == []

      assert Enum.map(EnvironmentPicker.available_matches(picker), & &1.short_name) |> Enum.sort() ==
               ["prod", "staging"]
    end

    @tag action: "DEX-A07"
    test "selected_count/1 excludes a selected_names entry absent from all, unlike selected_names/1" do
      picker = EnvironmentPicker.new([env("prod")], ["prod", "ghost-env"])

      assert Enum.sort(EnvironmentPicker.selected_names(picker)) == ["ghost-env", "prod"]
      assert EnvironmentPicker.selected_count(picker) == 1

      assert Enum.map(EnvironmentPicker.selected_matches(picker), & &1.short_name) ==
               ["prod"]
    end
  end

  describe "DEX-A08 — select/deselect via toggle" do
    @tag action: "DEX-A08"
    test "toggle/2 moves a short name from available to selected and back" do
      prod = env("prod")
      staging = env("staging")
      picker = EnvironmentPicker.new([prod, staging], [])

      picker = EnvironmentPicker.toggle(picker, "prod")
      assert EnvironmentPicker.selected_names(picker) == ["prod"]

      assert Enum.map(EnvironmentPicker.available_matches(picker), & &1.short_name) ==
               ["staging"]

      picker = EnvironmentPicker.toggle(picker, "prod")
      assert EnvironmentPicker.selected_names(picker) == []

      assert Enum.map(EnvironmentPicker.available_matches(picker), & &1.short_name) |> Enum.sort() ==
               ["prod", "staging"]
    end

    @tag action: "DEX-A08"
    test "selection is idempotent under a rapid double-toggle back to the original state" do
      picker = EnvironmentPicker.new([env("prod")], ["prod"])

      round_tripped =
        picker
        |> EnvironmentPicker.toggle("prod")
        |> EnvironmentPicker.toggle("prod")

      assert EnvironmentPicker.selected_names(round_tripped) ==
               EnvironmentPicker.selected_names(picker)
    end

    @tag action: "DEX-A08"
    test "selected_names/1 reflects toggles in call order, independent of all's original order" do
      picker = EnvironmentPicker.new([env("prod"), env("staging"), env("dev")], [])

      picker =
        picker
        |> EnvironmentPicker.toggle("dev")
        |> EnvironmentPicker.toggle("prod")

      assert Enum.sort(EnvironmentPicker.selected_names(picker)) == ["dev", "prod"]
    end
  end

  describe "DEX-A09 — filter narrows both lists without changing selection" do
    @tag action: "DEX-A09"
    test "filter/2 narrows available_matches/1 and selected_matches/1 by short_name, case-insensitively" do
      picker =
        [env("prod-east"), env("prod-west"), env("staging")]
        |> EnvironmentPicker.new(["prod-east"])
        |> EnvironmentPicker.filter("PROD")

      assert Enum.map(EnvironmentPicker.selected_matches(picker), & &1.short_name) ==
               ["prod-east"]

      assert Enum.map(EnvironmentPicker.available_matches(picker), & &1.short_name) ==
               ["prod-west"]
    end

    @tag action: "DEX-A09"
    test "filter/2 also matches against label, case-insensitively" do
      picker =
        [env("prod", "Production"), env("stg", "Staging")]
        |> EnvironmentPicker.new([])
        |> EnvironmentPicker.filter("stag")

      assert Enum.map(EnvironmentPicker.available_matches(picker), & &1.short_name) == ["stg"]
    end

    @tag action: "DEX-A09"
    test "a filtered-out selected environment remains selected" do
      picker =
        [env("prod"), env("staging")]
        |> EnvironmentPicker.new(["staging"])
        |> EnvironmentPicker.filter("prod")

      assert EnvironmentPicker.selected_matches(picker) == []
      assert EnvironmentPicker.selected_names(picker) == ["staging"]
      assert EnvironmentPicker.selected_count(picker) == 1
    end

    @tag action: "DEX-A09"
    test "clearing the filter restores the full lists" do
      picker =
        [env("prod"), env("staging")]
        |> EnvironmentPicker.new(["staging"])
        |> EnvironmentPicker.filter("prod")
        |> EnvironmentPicker.filter("")

      assert Enum.map(EnvironmentPicker.available_matches(picker), & &1.short_name) == ["prod"]
      assert Enum.map(EnvironmentPicker.selected_matches(picker), & &1.short_name) == ["staging"]
    end

    @tag action: "DEX-A09"
    test "a nil label does not crash the filter match" do
      picker =
        [env("prod", nil)]
        |> EnvironmentPicker.new([])
        |> EnvironmentPicker.filter("prod")

      assert Enum.map(EnvironmentPicker.available_matches(picker), & &1.short_name) == ["prod"]
    end
  end
end
