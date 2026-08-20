defmodule Nucleus.M2M.ClientIdTest do
  use ExUnit.Case, async: true

  alias Nucleus.Backend.Error
  alias Nucleus.M2M.ClientId

  describe "validate/1 — M2M-A13 shape (AWS's own pattern, Decision 5)" do
    @tag :unit
    test "accepts a real-shaped 26-character lowercase ID" do
      assert ClientId.validate(String.duplicate("a", 26)) == :ok
    end

    @tag :unit
    test "accepts uppercase — superseded by Decision 5" do
      assert ClientId.validate("ABCDEF") == :ok
    end

    @tag :unit
    test "accepts underscore and plus — AWS's own [\\w+]+ pattern" do
      assert ClientId.validate("abc_def") == :ok
      assert ClientId.validate("abc+def") == :ok
    end

    @tag :unit
    test "rejects empty, nil, and non-binary input" do
      for input <- ["", nil, :abc] do
        assert {:error, %Error{kind: :invalid}} = ClientId.validate(input)
      end
    end

    @tag :unit
    test "rejects path traversal, slashes, and hostile shapes" do
      hostile = [
        "../etc",
        "abc/def",
        "abc\\def",
        "ab\0c",
        "abc def",
        "%2e%2e",
        "abc\uFF0Fdef"
      ]

      for client_id <- hostile do
        assert {:error, %Error{kind: :invalid}} = ClientId.validate(client_id)
      end
    end

    @tag :unit
    test "rejects a 129-character ID" do
      assert {:error, %Error{kind: :invalid}} = ClientId.validate(String.duplicate("a", 129))
    end

    @tag :unit
    test "accepts a 128-character ID exactly" do
      assert ClientId.validate(String.duplicate("a", 128)) == :ok
    end
  end
end
