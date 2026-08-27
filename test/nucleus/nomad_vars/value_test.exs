defmodule Nucleus.NomadVars.ValueTest do
  use ExUnit.Case, async: true

  alias Nucleus.NomadVars.Value

  describe "validate/1 — DEX-A05 shape" do
    @tag :unit
    test "accepts a well-formed value" do
      assert Value.validate("prod,staging") == :ok
    end

    @tag :unit
    test "accepts exactly the maximum length" do
      assert Value.validate(String.duplicate("a", Value.max_length())) == :ok
    end

    @tag :unit
    test "rejects one character past the maximum length" do
      assert Value.validate(String.duplicate("a", Value.max_length() + 1)) == {:error, :too_long}
    end

    @tag :unit
    test "counts length in characters, not bytes — a multi-byte character at the boundary" do
      # "é" is one character but two bytes in UTF-8 — a byte-counting
      # implementation would reject this at 4096 characters.
      value = String.duplicate("é", Value.max_length())

      assert String.length(value) == Value.max_length()
      assert byte_size(value) > Value.max_length()
      assert Value.validate(value) == :ok
    end

    @tag :unit
    test "rejects empty and non-binary input as :empty" do
      for input <- ["", nil, :env_names, 42] do
        assert Value.validate(input) == {:error, :empty}
      end
    end
  end
end
