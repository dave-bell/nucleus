defmodule Nucleus.NomadVars.EnvNamesTest do
  use ExUnit.Case, async: true

  alias Nucleus.NomadVars.EnvNames

  describe "diff/2 — the add/remove delta, DEX-A10/AUD-A04" do
    @tag :unit
    @tag action: "AUD-A04"
    test "added-only: everything in new not in current" do
      assert EnvNames.diff(["prod"], ["prod", "staging"]) ==
               %{added: ["staging"], removed: []}
    end

    @tag :unit
    @tag action: "AUD-A04"
    test "removed-only: everything in current not in new" do
      assert EnvNames.diff(["prod", "staging"], ["prod"]) ==
               %{added: [], removed: ["staging"]}
    end

    @tag :unit
    @tag action: "AUD-A04"
    test "both added and removed at once" do
      assert EnvNames.diff(["prod", "staging"], ["prod", "qa"]) ==
               %{added: ["qa"], removed: ["staging"]}
    end

    @tag :unit
    @tag action: "AUD-A04"
    test "identical lists — neither added nor removed, still a fully-shaped delta" do
      assert EnvNames.diff(["prod", "staging"], ["prod", "staging"]) ==
               %{added: [], removed: []}
    end

    @tag :unit
    @tag action: "AUD-A04"
    test "both empty" do
      assert EnvNames.diff([], []) == %{added: [], removed: []}
    end

    @tag :unit
    @tag action: "AUD-A04"
    test "both sides are sorted, regardless of input order — deterministic audit output" do
      assert EnvNames.diff(["staging", "prod"], ["qa", "dev"]) ==
               %{added: ["dev", "qa"], removed: ["prod", "staging"]}
    end
  end

  describe "serialize/1 / parse/1 — the comma-separated round trip" do
    @tag :unit
    test "a multi-entry list survives parse(serialize(list))" do
      names = ["prod", "staging", "qa"]
      assert EnvNames.parse(EnvNames.serialize(names)) == names
    end

    @tag :unit
    test "a single-entry list survives the round trip" do
      assert EnvNames.parse(EnvNames.serialize(["prod"])) == ["prod"]
    end

    @tag :unit
    test "an empty list survives the round trip" do
      assert EnvNames.serialize([]) == ""
      assert EnvNames.parse(EnvNames.serialize([])) == []
    end

    @tag :unit
    test "serialize/1 joins with a comma and no extra whitespace" do
      assert EnvNames.serialize(["prod", "staging"]) == "prod,staging"
    end
  end

  describe "parse/1 — tolerant of stray whitespace and blank entries" do
    @tag :unit
    test "nil and an empty string both parse to []" do
      assert EnvNames.parse(nil) == []
      assert EnvNames.parse("") == []
    end

    @tag :unit
    test "entries with stray spaces are trimmed" do
      assert EnvNames.parse(" prod , staging ") == ["prod", "staging"]
    end

    @tag :unit
    test "blank entries between, or trailing, commas are dropped" do
      assert EnvNames.parse("prod,,staging,") == ["prod", "staging"]
      assert EnvNames.parse(",,") == []
    end

    @tag :unit
    test "a single entry with no comma parses to a one-element list" do
      assert EnvNames.parse("prod") == ["prod"]
    end
  end
end
