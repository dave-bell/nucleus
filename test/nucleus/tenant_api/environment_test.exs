defmodule Nucleus.TenantApi.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Nucleus.TenantApi.Environment

  doctest Environment

  describe "naming translation" do
    test "camelCase becomes snake_case, and isArchived becomes a predicate" do
      assert {:ok, environment} =
               Environment.from_api(%{
                 "shortName" => "prod",
                 "label" => "Production",
                 "iri" => "https://tenant.example.com/environment/prod",
                 "accentColor" => "#b91c1c",
                 "categories" => ["Customer Facing"],
                 "isArchived" => true,
                 "description" => "Live traffic."
               })

      assert environment.short_name == "prod"
      assert environment.label == "Production"
      assert environment.iri == "https://tenant.example.com/environment/prod"
      assert environment.accent_color == "#b91c1c"
      assert environment.categories == ["Customer Facing"]
      assert environment.archived? == true
      assert environment.description == "Live traffic."
    end

    test "no camelCase key survives onto the struct" do
      assert {:ok, environment} = Environment.from_api(%{"shortName" => "prod"})

      keys = environment |> Map.from_struct() |> Map.keys() |> Enum.map(&Atom.to_string/1)

      refute Enum.any?(keys, &(&1 =~ ~r/[a-z][A-Z]/))
    end
  end

  describe "short_name" do
    test "is required" do
      assert Environment.from_api(%{"label" => "Production"}) == {:error, :missing_short_name}
    end

    test "rejects nil, empty and whitespace-only, so no path segment is ever blank" do
      for value <- [nil, "", "   ", "\t\n"] do
        assert Environment.from_api(%{"shortName" => value}) == {:error, :missing_short_name}
      end
    end

    test "rejects a non-string" do
      assert Environment.from_api(%{"shortName" => 42}) == {:error, :missing_short_name}
    end

    test "cannot be omitted when building the struct directly either" do
      assert_raise ArgumentError, fn -> struct!(Environment, label: "Production") end
    end
  end

  describe "one absence case per optional field" do
    test "an omitted description is nil" do
      assert {:ok, %Environment{description: nil}} = Environment.from_api(%{"shortName" => "x"})
    end

    test "a blank description is nil, not an empty string" do
      for value <- ["", "   "] do
        assert {:ok, %Environment{description: nil}} =
                 Environment.from_api(%{"shortName" => "x", "description" => value})
      end
    end

    test "blank optional strings all normalise to nil" do
      assert {:ok, environment} =
               Environment.from_api(%{
                 "shortName" => "x",
                 "label" => "",
                 "iri" => "",
                 "accentColor" => ""
               })

      assert environment.label == nil
      assert environment.iri == nil
      assert environment.accent_color == nil
    end
  end

  describe "categories" do
    test "an omitted or null list is an empty list, never nil" do
      assert {:ok, %Environment{categories: []}} = Environment.from_api(%{"shortName" => "x"})

      assert {:ok, %Environment{categories: []}} =
               Environment.from_api(%{"shortName" => "x", "categories" => nil})
    end

    test "is rejected when it is not a list of strings" do
      for value <- ["Customer Facing", %{"name" => "x"}, [%{"name" => "x"}], [1]] do
        assert Environment.from_api(%{"shortName" => "x", "categories" => value}) ==
                 {:error, :invalid_categories}
      end
    end
  end

  describe "archived?" do
    test "defaults to false when absent" do
      assert {:ok, %Environment{archived?: false}} = Environment.from_api(%{"shortName" => "x"})
    end

    test "is rejected when it is not a boolean" do
      for value <- ["true", 1] do
        assert Environment.from_api(%{"shortName" => "x", "isArchived" => value}) ==
                 {:error, :invalid_archived}
      end
    end
  end

  describe "from_api_list/1" do
    test "preserves order" do
      assert {:ok, environments} =
               Environment.from_api_list([
                 %{"shortName" => "prod"},
                 %{"shortName" => "staging"},
                 %{"shortName" => "dev"}
               ])

      assert Enum.map(environments, & &1.short_name) == ["prod", "staging", "dev"]
    end

    test "fails the whole list on one bad element, returning no partial result" do
      # All or nothing: a caller handed the three good elements has no way to know
      # a fourth existed, and cannot tell that tenant from one with three.
      assert Environment.from_api_list([
               %{"shortName" => "prod"},
               %{"shortName" => "staging"},
               %{"shortName" => ""},
               %{"shortName" => "dev"}
             ]) == {:error, :missing_short_name}
    end

    test "rejects a non-list and a non-object element" do
      assert Environment.from_api_list(%{"environments" => []}) == {:error, :not_an_object}
      assert Environment.from_api_list(["prod"]) == {:error, :not_an_object}
    end

    test "an empty list is a valid answer" do
      assert Environment.from_api_list([]) == {:ok, []}
    end
  end
end
