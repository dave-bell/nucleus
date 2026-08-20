defmodule Nucleus.M2M.DenyListTest do
  # Mutates the node-global Nucleus.M2M.DenyList suffixes config.
  use ExUnit.Case, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.M2M.DenyList

  setup do
    original = Application.get_env(:nucleus, DenyList, [])
    on_exit(fn -> Application.put_env(:nucleus, DenyList, original) end)
    :ok
  end

  defp put_suffixes(suffixes) do
    Application.put_env(:nucleus, DenyList, suffixes: suffixes)
  end

  defp unconfigure do
    Application.put_env(:nucleus, DenyList, [])
  end

  describe "parse/1 — pure" do
    @tag :unit
    test "nil, blank, and all-empty-after-split values are :unset" do
      for value <- [nil, "", "   ", ",", ",,"] do
        assert DenyList.parse(value) == :unset
      end
    end

    @tag :unit
    test "the literal sentinel none (case-insensitive) is an explicit empty list" do
      assert DenyList.parse("none") == {:ok, []}
      assert DenyList.parse("NONE") == {:ok, []}
      assert DenyList.parse("None") == {:ok, []}
    end

    @tag :unit
    test "the real Terraform value parses to the six-entry trimmed, downcased list" do
      raw = "-labops-ui,-faas-api,-faas-ui,-device_grant,-orange,-nucleus"

      assert DenyList.parse(raw) ==
               {:ok,
                ["-labops-ui", "-faas-api", "-faas-ui", "-device_grant", "-orange", "-nucleus"]}
    end

    @tag :unit
    test "entries with stray spaces parse the same as without" do
      assert DenyList.parse(" -orange , -nucleus ") == {:ok, ["-orange", "-nucleus"]}
    end

    @tag :unit
    test "entries are downcased" do
      assert DenyList.parse("-NUCLEUS,-Orange") == {:ok, ["-nucleus", "-orange"]}
    end
  end

  describe "suffixes/0 — call-time config read" do
    @tag :unit
    test "returns the configured list" do
      put_suffixes(["-nucleus", "-orange"])
      assert DenyList.suffixes() == {:ok, ["-nucleus", "-orange"]}
    end

    @tag :unit
    test "unset or blank configuration returns :not_configured" do
      unconfigure()

      assert {:error, %Error{kind: :not_configured}} = DenyList.suffixes()
    end
  end

  describe "denied?/1" do
    @tag :unit
    test "configured suffixes match on the end of a name only, never in the middle" do
      put_suffixes(["-nucleus"])

      refute DenyList.denied?("local-control-plane-OPS-1-nucleus-sync")
      assert DenyList.denied?("local-control-plane-OPS-1-nucleus")
    end

    @tag :unit
    test "matching is case-insensitive" do
      put_suffixes(["-nucleus"])

      assert DenyList.denied?("local-control-plane-OPS-1-NUCLEUS")
      assert DenyList.denied?("LOCAL-CONTROL-PLANE-OPS-1-nucleus")
    end

    @tag :unit
    test "a suffix containing regex metacharacters is treated literally" do
      put_suffixes(["-a.b"])

      assert DenyList.denied?("client-a.b")
      refute DenyList.denied?("client-axb")
    end

    @tag :unit
    test "matches a conforming name built from a reserved purpose — the creation-guard case (Decision 9, §9)" do
      put_suffixes([
        "-labops-ui",
        "-faas-api",
        "-faas-ui",
        "-device_grant",
        "-orange",
        "-nucleus"
      ])

      assert DenyList.denied?("local-control-plane-OPS-1042-nucleus")
    end

    @tag :unit
    test "an explicitly empty list denies nothing" do
      put_suffixes([])

      refute DenyList.denied?("local-control-plane-OPS-1042-nucleus")
    end
  end
end
