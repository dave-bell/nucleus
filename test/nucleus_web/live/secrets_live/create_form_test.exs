defmodule NucleusWeb.SecretsLive.CreateFormTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias NucleusWeb.SecretsLive.CreateForm

  describe "changeset/3 — SEC-A10 duplicate detection" do
    @tag action: "SEC-A10"
    @tag :unit
    test "a key already in existing_keys is rejected on the key field" do
      changeset =
        CreateForm.changeset(%CreateForm{}, %{"key" => "API_KEY", "value" => "s3cr3t"}, [
          "API_KEY"
        ])

      refute changeset.valid?
      assert %{key: [message]} = errors_on(changeset)
      assert message =~ "already exists in this environment"
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "duplicate detection is case-sensitive: existing [\"API_KEY\"] does not block \"api_key\"" do
      changeset =
        CreateForm.changeset(%CreateForm{}, %{"key" => "api_key", "value" => "s3cr3t"}, [
          "API_KEY"
        ])

      assert changeset.valid?
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "a key not in existing_keys is accepted" do
      changeset =
        CreateForm.changeset(%CreateForm{}, %{"key" => "NEW_KEY", "value" => "s3cr3t"}, [
          "OTHER_KEY"
        ])

      assert changeset.valid?
    end
  end

  describe "changeset/3 — SEC-A10 key shape errors reach the changeset" do
    @tag action: "SEC-A10"
    @tag :unit
    test "distinct messages per key rule reach the changeset" do
      cases = [
        {"a/b", "forward slash"},
        {String.duplicate("a", 257), "256 characters"},
        {"..", "path-traversal"}
      ]

      for {key, expected_fragment} <- cases do
        changeset = CreateForm.changeset(%CreateForm{}, %{"key" => key, "value" => "v"}, [])

        refute changeset.valid?
        assert %{key: [message]} = errors_on(changeset)

        assert message =~ expected_fragment,
               "expected #{inspect(key)}'s message to mention #{inspect(expected_fragment)}, got #{inspect(message)}"
      end
    end

    @tag action: "SEC-A10"
    @tag :unit
    test "an empty key shows exactly one error, not two stacked" do
      changeset = CreateForm.changeset(%CreateForm{}, %{"key" => "", "value" => "v"}, [])

      refute changeset.valid?
      assert %{key: [_one_message]} = errors_on(changeset)
    end
  end

  describe "changeset/3 — SEC-A11 value validation" do
    @tag action: "SEC-A11"
    @tag :unit
    test "an empty value is invalid" do
      changeset = CreateForm.changeset(%CreateForm{}, %{"key" => "K", "value" => ""}, [])

      refute changeset.valid?
      assert %{value: [_message]} = errors_on(changeset)
    end

    @tag action: "SEC-A11"
    @tag :unit
    test "a 4097-character value is invalid" do
      changeset =
        CreateForm.changeset(
          %CreateForm{},
          %{"key" => "K", "value" => String.duplicate("a", 4097)},
          []
        )

      refute changeset.valid?
      assert %{value: [message]} = errors_on(changeset)
      assert message =~ "4096"
    end

    @tag action: "SEC-A11"
    @tag :unit
    test "a 4096-character value is valid" do
      changeset =
        CreateForm.changeset(
          %CreateForm{},
          %{"key" => "K", "value" => String.duplicate("a", 4096)},
          []
        )

      assert changeset.valid?
    end
  end

  describe "changeset/3 — a valid key and value together" do
    @tag action: "SEC-A09"
    @tag :unit
    test "produces a valid changeset with both fields readable via get_field/2" do
      changeset =
        CreateForm.changeset(
          %CreateForm{},
          %{"key" => "DATABASE_URL", "value" => "postgres://"},
          []
        )

      assert changeset.valid?
      assert Changeset.get_field(changeset, :key) == "DATABASE_URL"
      assert Changeset.get_field(changeset, :value) == "postgres://"
    end
  end

  defp errors_on(changeset) do
    Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
