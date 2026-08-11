defmodule NucleusTest.TenantApiContract do
  @moduledoc """
  Assertions every `Nucleus.TenantApi` implementation must satisfy.

  Two implementations of a boundary are two chances to be wrong in different
  ways. `Nucleus.TenantApi.Local` is what every developer and every CI job runs
  against, so if it drifts from `Nucleus.TenantApi.Http` the whole local-backend
  approach stops being worth anything — the suite would be green against
  behaviour production never exhibits.

  These are plain functions rather than a `__using__` macro so the assertions are
  literally shared, not generated twice: `test/nucleus/tenant_api/contract_test.exs`
  calls the same function for both implementations.

  EN-8 owns the general harness for this pattern. This module is the first
  instance of it, not the abstraction — resist generalising it until there is a
  second boundary to generalise from.
  """

  import ExUnit.Assertions

  alias Nucleus.TenantApi.Environment

  @doc """
  Asserts `impl` returns a usable environment list.
  """
  def assert_lists_environments(impl) do
    assert {:ok, environments} = impl.list_environments(nil)
    assert is_list(environments)

    environments
  end

  @doc """
  Asserts every element is a fully-formed `%Environment{}`.

  `short_name` is checked hardest because it becomes a URL segment *and* a
  Parameter Store path segment: a `nil` or blank one builds a path that
  addresses the wrong thing (`SEC-A15`–`A17`).
  """
  def assert_element_shape(impl) do
    for environment <- assert_lists_environments(impl) do
      assert %Environment{} = environment

      assert is_binary(environment.short_name),
             "short_name must be a binary, got: #{inspect(environment.short_name)}"

      assert String.trim(environment.short_name) != "", "short_name must not be blank"

      assert is_list(environment.categories),
             "categories must always be a list, never nil"

      assert Enum.all?(environment.categories, &is_binary/1),
             "categories must be a list of strings"

      assert is_boolean(environment.archived?),
             "archived? must always be a boolean"
    end
  end

  @doc """
  Asserts optional strings have exactly one absence value.

  `ENV-A02` requires a description be shown when present and omitted when not.
  A template that has to test both `nil` and `""` will eventually test only one,
  so both implementations must collapse blank to `nil`.
  """
  def assert_one_absence_case(impl) do
    for environment <- assert_lists_environments(impl),
        {field, value} <- Map.take(environment, [:label, :iri, :accent_color, :description]) do
      assert is_nil(value) or (is_binary(value) and String.trim(value) != ""),
             "#{field} must be nil or a non-blank binary, got: #{inspect(value)}"
    end
  end

  @doc """
  Asserts `impl` reports itself reachable.
  """
  def assert_health_check(impl) do
    assert impl.health_check() == :ok
  end
end
