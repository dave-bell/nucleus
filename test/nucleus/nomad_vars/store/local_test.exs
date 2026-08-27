defmodule Nucleus.NomadVars.Store.LocalTest do
  # Fault injection is read from the OS environment, which is global to the node.
  use ExUnit.Case, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Seed
  alias Nucleus.NomadVars.Store.Local
  alias Nucleus.NomadVars.VariableSet

  setup do
    on_exit(&Seed.reset/0)
    :ok
  end

  defp force_error(kind) do
    System.put_env("LOCAL_FORCE_ERROR", kind)
    on_exit(fn -> System.delete_env("LOCAL_FORCE_ERROR") end)
  end

  describe "the seeded fixture" do
    test "read/0 decodes the checked-in local-data_export variable set" do
      assert {:ok, %VariableSet{} = variable_set} = Local.read()
      assert variable_set.path == "nomad/jobs/local-data_export"
      assert variable_set.items["description"] =~ "usage metrics"
      assert variable_set.modify_index == 42
      assert %DateTime{} = variable_set.modified_at
    end
  end

  describe "write/2" do
    test "replaces the entire Items map, never merging" do
      assert {:ok, %VariableSet{modify_index: current}} = Local.read()

      assert {:ok, %VariableSet{items: items}} =
               Local.write(%{"description" => "only this key now"}, current)

      assert items == %{"description" => "only this key now"}
    end

    test "bumps the modify index and modified_at on a successful write" do
      assert {:ok, %VariableSet{modify_index: before_index, modified_at: before_time}} =
               Local.read()

      assert {:ok, %VariableSet{modify_index: after_index, modified_at: after_time}} =
               Local.write(%{"description" => "updated"}, before_index)

      assert after_index == before_index + 1
      assert DateTime.compare(after_time, before_time) == :gt
    end

    test "a stale expected_modify_index is :conflict, never silently applied" do
      assert {:ok, %VariableSet{modify_index: current, items: original_items}} = Local.read()

      assert {:error, %Error{kind: :conflict, boundary: :nomad_vars, details: details}} =
               Local.write(%{"description" => "should not apply"}, current - 1)

      assert details.modify_index == current
      assert {:ok, %VariableSet{items: ^original_items}} = Local.read()
    end

    test "two concurrent writers against the same expected_modify_index — exactly one wins" do
      # Regression test: write/2 must perform its CAS check and its write
      # inside the same atomic step (Nucleus.Backend.Seed.get_and_update/3),
      # not a Seed.read/1 followed by a separate Seed.update/2 — the latter
      # lets two callers both read the same current index, both pass the
      # check, and have the second silently clobber the first with neither
      # ever seeing a :conflict.
      assert {:ok, %VariableSet{modify_index: current}} = Local.read()

      results =
        1..20
        |> Task.async_stream(fn i -> Local.write(%{"description" => "writer #{i}"}, current) end)
        |> Enum.map(fn {:ok, result} -> result end)

      successes = Enum.filter(results, &match?({:ok, _}, &1))
      conflicts = Enum.filter(results, &match?({:error, %Error{kind: :conflict}}, &1))

      assert length(successes) == 1
      assert length(conflicts) == 19

      # The stored index only advanced by the one write that actually won.
      assert {:ok, %VariableSet{modify_index: final_index}} = Local.read()
      assert final_index == current + 1
    end
  end

  describe "state resets between tests" do
    test "part one: writes a new value" do
      assert {:ok, %VariableSet{modify_index: current}} = Local.read()
      assert {:ok, _} = Local.write(%{"description" => "RESET_PROBE"}, current)
    end

    test "part two: the previous test's write is gone" do
      assert {:ok, %VariableSet{items: items}} = Local.read()
      refute items["description"] == "RESET_PROBE"
    end
  end

  describe "fault injection" do
    @kinds Error.kinds()

    test "LOCAL_FORCE_ERROR=auth_expired surfaces on every callback" do
      force_error("auth_expired")

      assert {:error, %Error{kind: :auth_expired}} = Local.read()
      assert {:error, %Error{kind: :auth_expired}} = Local.write(%{}, 0)
      assert {:error, %Error{kind: :auth_expired}} = Local.health_check()
    end

    test "every declared Error kind is a valid LOCAL_FORCE_ERROR value" do
      for kind <- @kinds do
        force_error(Atom.to_string(kind))
        assert {:error, %Error{kind: ^kind}} = Local.health_check()
        System.delete_env("LOCAL_FORCE_ERROR")
      end
    end

    test "an unparseable value raises rather than passing silently" do
      force_error("teapot")

      assert_raise ArgumentError, fn -> Local.read() end
    end
  end

  describe "a broken or absent seed section" do
    test "reads as :not_configured when the section is absent" do
      Seed.write(:nomad_vars, nil)

      assert {:error, %Error{kind: :not_configured}} = Local.read()
    end

    test "reads as :not_configured when the section is malformed" do
      Seed.write(:nomad_vars, %{"not" => "a variable set"})

      assert {:error, %Error{kind: :not_configured}} = Local.read()
    end

    test "fails health_check/0 when the section is absent" do
      Seed.write(:nomad_vars, nil)

      assert {:error, %Error{kind: :not_configured}} = Local.health_check()
    end
  end

  describe "a tenant without Data Export enabled — distinct from :not_configured" do
    test "reads as :not_found when the section is the JSON literal false" do
      Seed.write(:nomad_vars, false)

      assert {:error, %Error{kind: :not_found, boundary: :nomad_vars}} = Local.read()
    end

    test "fails health_check/0 with :ok — false still means reachable, matching Http's contract" do
      Seed.write(:nomad_vars, false)

      # `:not_found` (this tenant lacks the feature) is reachability, not an
      # outage — health_check/0 must not report the boundary unhealthy for a
      # state Nucleus.NomadVars.Store.Http itself treats as :ok.
      assert Local.health_check() == :ok
    end

    test "is distinct from :not_configured — the two fixtures behave differently" do
      Seed.write(:nomad_vars, nil)
      assert {:error, %Error{kind: :not_configured}} = Local.read()

      Seed.write(:nomad_vars, false)
      assert {:error, %Error{kind: :not_found}} = Local.read()
    end
  end
end
