defmodule NucleusTest.NomadVarsContract do
  @moduledoc """
  Assertions every `Nucleus.NomadVars.Store` implementation must satisfy.

  Plain functions, not a `__using__` macro — same pattern as
  `NucleusTest.NomadJobsContract` and `NucleusTest.SecretsStoreContract`, so
  the assertions are literally shared between `Local` and `Http` rather than
  generated twice.

  Mutation assertions (`assert_write_*`) are called only against `Local` from
  `test/nucleus/nomad_vars/contract_test.exs` — a test suite must never
  write to a real tenant's Nomad Variables, the same rule
  `NucleusTest.SecretsStoreContract` states for Parameter Store.
  """

  import ExUnit.Assertions

  alias Nucleus.Backend.Error
  alias Nucleus.NomadVars.VariableSet

  @doc """
  Asserts `impl.read/0` returns a fully-formed `%VariableSet{}`.
  """
  def assert_reads_variable_set(impl) do
    assert {:ok, %VariableSet{} = variable_set} = impl.read()
    assert is_binary(variable_set.path) and variable_set.path != ""
    assert is_map(variable_set.items)
    assert is_integer(variable_set.modify_index)

    variable_set
  end

  @doc """
  Asserts a write with the current modify index replaces `items` and returns
  the bumped index, never merging with what was already stored.
  """
  def assert_write_updates_items(impl, new_items) do
    assert {:ok, %VariableSet{modify_index: before_index}} = impl.read()

    assert {:ok, %VariableSet{} = written} = impl.write(new_items, before_index)
    assert written.items == new_items
    assert written.modify_index > before_index

    assert {:ok, %VariableSet{items: ^new_items}} = impl.read()
  end

  @doc """
  Asserts a write against a stale modify index is rejected as `:conflict`,
  never silently applied.
  """
  def assert_write_conflict_on_stale_index(impl, items) do
    assert {:ok, %VariableSet{modify_index: current}} = impl.read()
    stale = current - 1

    assert {:error, %Error{kind: :conflict}} = impl.write(items, stale)

    # The stale write must not have applied.
    assert {:ok, %VariableSet{modify_index: ^current}} = impl.read()
  end

  @doc """
  Asserts `impl` reports itself reachable.
  """
  def assert_health_check(impl) do
    assert impl.health_check() == :ok
  end
end
