defmodule Nucleus.M2M.TokenValidityTest do
  use ExUnit.Case, async: true

  alias Nucleus.M2M.TokenValidity

  doctest TokenValidity

  describe "humanize/1 — hours" do
    @tag action: "M2M-A16"
    @tag :unit
    test "exactly one hour reads singular" do
      assert TokenValidity.humanize(3600) == "1 hour"
    end

    @tag action: "M2M-A16"
    test "a whole number of hours other than one pluralises" do
      assert TokenValidity.humanize(7200) == "2 hours"
      assert TokenValidity.humanize(24 * 3600) == "24 hours"
    end
  end

  describe "humanize/1 — minutes (whole minutes, not whole hours)" do
    @tag action: "M2M-A16"
    @tag :unit
    test "exactly one minute reads singular" do
      assert TokenValidity.humanize(60) == "1 minute"
    end

    @tag action: "M2M-A16"
    test "a whole number of minutes other than one pluralises" do
      assert TokenValidity.humanize(900) == "15 minutes"
      assert TokenValidity.humanize(1800) == "30 minutes"
    end
  end

  describe "humanize/1 — seconds (neither whole hours nor whole minutes)" do
    @tag action: "M2M-A16"
    @tag :unit
    test "exactly one second reads singular" do
      assert TokenValidity.humanize(1) == "1 second"
    end

    @tag action: "M2M-A16"
    test "a value that is not a whole number of minutes pluralises in seconds" do
      assert TokenValidity.humanize(450) == "450 seconds"
    end
  end

  describe "humanize/1 — nil" do
    @tag action: "M2M-A16"
    @tag :unit
    test "yields a neutral string, not \"nil hours\" or a crash" do
      assert TokenValidity.humanize(nil) == "not set"
    end
  end

  describe "humanize/1 — the exact singular/plural boundary" do
    @tag action: "M2M-A16"
    test "1 and 2 produce different suffixes at every tier" do
      assert TokenValidity.humanize(3600) == "1 hour"
      assert TokenValidity.humanize(2 * 3600) == "2 hours"

      assert TokenValidity.humanize(60) == "1 minute"
      assert TokenValidity.humanize(120) == "2 minutes"

      assert TokenValidity.humanize(1) == "1 second"
      assert TokenValidity.humanize(2) == "2 seconds"
    end
  end

  describe "humanize/1 — largest exact unit wins" do
    @tag action: "M2M-A16"
    test "a value that is a whole number of both hours and minutes reads in hours" do
      assert TokenValidity.humanize(3600) == "1 hour"
    end

    @tag action: "M2M-A16"
    test "a value that is a whole number of minutes but not hours reads in minutes" do
      assert TokenValidity.humanize(900) == "15 minutes"
    end
  end
end
