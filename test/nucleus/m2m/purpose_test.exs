defmodule Nucleus.M2M.PurposeTest do
  use ExUnit.Case, async: true

  alias Nucleus.M2M.Purpose

  describe "validate/1 — M2M-A06 shape" do
    @tag :unit
    test "accepts well-formed purposes" do
      for purpose <- ["nightly-sync", "a", "sync2", "a-b-c", String.duplicate("a", 32)] do
        assert Purpose.validate(purpose) == :ok
      end
    end

    @tag :unit
    test "accepts a double hyphen — the requirement only forbids leading/trailing" do
      assert Purpose.validate("nightly--sync") == :ok
    end

    @tag :unit
    test "rejects a purpose one character past the 32-character boundary" do
      assert Purpose.validate(String.duplicate("a", 33)) == {:error, :too_long}
    end

    @tag :unit
    test "rejects empty, whitespace-only, and non-binary input as :empty" do
      for input <- ["", "   ", nil, :sync] do
        assert Purpose.validate(input) == {:error, :empty}
      end
    end

    @tag :unit
    test "rejects an invalid charset as :charset" do
      for purpose <- ["Nightly-Sync", "nightly sync", "nightly_sync"] do
        assert Purpose.validate(purpose) == {:error, :charset}
      end
    end

    @tag :unit
    test "rejects a leading hyphen as :leading_hyphen" do
      assert Purpose.validate("-sync") == {:error, :leading_hyphen}
    end

    @tag :unit
    test "rejects a trailing hyphen as :trailing_hyphen" do
      assert Purpose.validate("sync-") == {:error, :trailing_hyphen}
    end

    @tag :unit
    test "reports the same reason deterministically for a purpose violating charset and length" do
      purpose = String.duplicate("A", 33)

      assert Purpose.validate(purpose) == {:error, :too_long}
      assert Purpose.validate(purpose) == {:error, :too_long}
    end
  end
end
