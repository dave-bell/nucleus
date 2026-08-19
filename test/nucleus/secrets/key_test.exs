defmodule Nucleus.Secrets.KeyTest do
  use ExUnit.Case, async: true

  alias Nucleus.Backend.Error
  alias Nucleus.Secrets.Key

  describe "validate/1 — SEC-A10 each rule reports its own reason" do
    @tag action: "SEC-A10"
    @tag :unit
    test "empty and whitespace-only" do
      for key <- ["", "   "] do
        assert {:error, %Error{kind: :invalid} = error} = Key.validate(key)
        assert error.details.reason == :empty
      end
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "exceeds 256 characters" do
      key = String.duplicate("a", 257)

      assert {:error, %Error{kind: :invalid} = error} = Key.validate(key)
      assert error.details.reason == :too_long
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "contains a forward slash" do
      assert {:error, %Error{kind: :invalid} = error} = Key.validate("a/b")
      assert error.details.reason == :forward_slash
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "contains a backslash" do
      assert {:error, %Error{kind: :invalid} = error} = Key.validate("a\\b")
      assert error.details.reason == :backslash
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "contains a null byte" do
      assert {:error, %Error{kind: :invalid} = error} = Key.validate("a\0b")
      assert error.details.reason == :null_byte
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "contains a path-traversal sequence" do
      for key <- ["a..b", "..", "../x"] do
        assert {:error, %Error{kind: :invalid} = error} = Key.validate(key)
        assert error.details.reason == :path_traversal,
               "expected #{inspect(key)} to report :path_traversal, got #{inspect(error.details.reason)}"
      end
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "each reason carries its own distinct message" do
      messages =
        for key <- ["", "a/b", "a\\b", "a\0b", "..", String.duplicate("a", 257)] do
          {:error, error} = Key.validate(key)
          error.message
        end

      assert Enum.uniq(messages) == messages,
             "expected every rule to produce a distinct message, got #{inspect(messages)}"
    end
  end

  describe "validate/1 — SEC-A10 accepts legitimate keys" do
    @tag action: "SEC-A10"
    @tag :unit
    test "plausible real-world keys" do
      valid = ["API_KEY", "db.password", "my-key", "a", String.duplicate("a", 256)]

      for key <- valid do
        assert Key.validate(key) == :ok, "expected #{inspect(key)} to be accepted"
      end
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "no casing constraint — mixed, upper, and lower case all pass" do
      for key <- ["DATABASE_URL", "database_url", "Database_Url"] do
        assert Key.validate(key) == :ok, "expected #{inspect(key)} to be accepted"
      end
    end
  end

  describe "validate/1 — SEC-A10 exact boundary" do
    @tag action: "SEC-A10"
    @tag :unit
    test "256 characters passes, 257 fails" do
      assert Key.validate(String.duplicate("a", 256)) == :ok

      assert {:error, %Error{} = error} = Key.validate(String.duplicate("a", 257))
      assert error.details.reason == :too_long
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "a multi-byte 256-character key passes (String.length, not byte_size)" do
      # Each "é" is two bytes in UTF-8, so this is 256 characters but 512 bytes.
      key = String.duplicate("é", 256)

      assert String.length(key) == 256
      assert Key.validate(key) == :ok
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "a multi-byte 257-character key fails" do
      key = String.duplicate("é", 257)

      assert {:error, %Error{} = error} = Key.validate(key)
      assert error.details.reason == :too_long
    end
  end

  describe "validate/1 — a key violating two rules reports deterministically" do
    @tag action: "SEC-A10"
    @tag :unit
    test "path traversal wins over forward slash, since \"..\" also contains \"/\"" do
      assert {:error, %Error{} = error} = Key.validate("../etc/passwd")
      assert error.details.reason == :path_traversal
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "the same input always reports the same reason" do
      key = "../etc/passwd"

      results = for _ <- 1..5, do: Key.validate(key)

      assert Enum.uniq(results) == [Enum.at(results, 0)]
    end
  end

  describe "validate/1 — non-string input" do
    @tag action: "SEC-A10"
    @tag :unit
    test "rejects non-binary terms without raising" do
      for term <- [nil, 123, :api_key] do
        assert {:error, %Error{kind: :invalid}} = Key.validate(term)
      end
    end
  end
end
