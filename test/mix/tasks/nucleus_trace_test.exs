defmodule Mix.Tasks.Nucleus.TraceTest do
  @moduledoc """
  Self-tests for `mix nucleus.trace`. The 114 canary in particular: if the
  `docs/requirements/` submodule is updated and this count moves, that is a
  signal to re-read the requirements, not a bug — see the task's own
  moduledoc and `business-tech-bridge.md`.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Nucleus.Trace

  @fixture_requirements_glob "test/fixtures/nucleus_trace/requirements/*.md"
  @fixture_claims_glob "test/fixtures/nucleus_trace/claims/*.txt"

  describe "against the real, pinned requirements submodule" do
    @tag :unit
    test "finds exactly 114 defined action ids" do
      assert MapSet.size(Trace.defined_action_ids()) == 114
    end

    @tag :unit
    test "excludes Home.md's worked example even though its header matches the same pattern" do
      refute MapSet.size(Trace.defined_action_ids("docs/requirements/Home.md")) > 0
    end

    @tag :unit
    test "--feature SEC filters the report to the 18 Secrets actions" do
      result = Trace.report(feature: "SEC")

      assert MapSet.size(result.defined) == 18
      assert Enum.all?(result.defined, &String.starts_with?(&1, "SEC-"))
    end

    @tag :unit
    test "a feature prefix with no requirements reports zero defined, not an error" do
      result = Trace.report(feature: "NOPE")

      assert MapSet.size(result.defined) == 0
      assert MapSet.size(result.uncovered) == 0
    end
  end

  describe "against fixture requirements and claims" do
    @tag :unit
    test "defined_action_ids/1 excludes a fixture Home.md by filename, not content" do
      ids = Trace.defined_action_ids(@fixture_requirements_glob)

      assert ids == MapSet.new(["FIX-A01", "FIX-A02"])
      refute "FIX-A99" in ids
    end

    @tag :unit
    test "claimed_action_ids/1 finds every @tag action: in the matched files" do
      assert Trace.claimed_action_ids(@fixture_claims_glob) == MapSet.new(["FIX-A01", "FIX-A77"])
    end

    @tag :unit
    test "reports an uncovered action when no test claims it" do
      result =
        Trace.report(
          requirements_glob: @fixture_requirements_glob,
          claimed_glob: "test/fixtures/nucleus_trace/claims/nonexistent/*.txt"
        )

      assert result.uncovered == MapSet.new(["FIX-A01", "FIX-A02"])
      assert result.covered == MapSet.new()
      assert Trace.uncovered?(result)
    end

    @tag :unit
    test "reports claimed-but-undefined for a bogus id, and covered for a real one" do
      result =
        Trace.report(
          requirements_glob: @fixture_requirements_glob,
          claimed_glob: @fixture_claims_glob
        )

      assert result.covered == MapSet.new(["FIX-A01"])
      assert result.uncovered == MapSet.new(["FIX-A02"])
      assert result.claimed_but_undefined == MapSet.new(["FIX-A77"])
    end

    @tag :unit
    test "uncovered?/1 is false once every defined action is claimed" do
      result =
        Trace.report(
          requirements_glob: @fixture_requirements_glob,
          claimed_glob: "test/fixtures/nucleus_trace/claims_full/*.txt"
        )

      assert result.covered == MapSet.new(["FIX-A01", "FIX-A02"])
      refute Trace.uncovered?(result)
    end
  end
end
