defmodule NucleusTest.SecretsStoreContract do
  @moduledoc """
  Assertions every `Nucleus.Secrets.Store` implementation must satisfy.

  Plain functions, not a `__using__` macro, so the assertions are literally
  shared between `Local` and `Aws` rather than generated twice — see
  `NucleusTest.TenantApiContract` for the same pattern and its rationale.
  EN-8 owns the general harness; this is the second instance of the pattern,
  not a generalisation of it.

  Mutation assertions here are called **only** against `Local` from
  `test/nucleus/secrets/store/contract_test.exs` — per ADR-0007, a test suite
  must never mutate a real tenant's parameters.
  """

  import ExUnit.Assertions

  alias Nucleus.Backend.Error
  alias Nucleus.Secrets.Secret
  alias Nucleus.Secrets.SecretLocation
  alias Nucleus.Secrets.SecretRef

  # -- Read assertions ---------------------------------------------------

  @doc """
  Every element of `impl.list_secrets(environment)` is a fully-formed
  `%SecretRef{}` — `SEC-A01` requires `key`/`path`/`arn` for reference and
  copying, and the struct's absent `:value` field makes leaking one
  structurally impossible.
  """
  def assert_list_secrets_shape(impl, environment) do
    assert {:ok, refs} = impl.list_secrets(environment)
    assert is_list(refs)

    for ref <- refs do
      assert %SecretRef{} = ref
      assert is_binary(ref.key) and ref.key != ""
      assert is_binary(ref.path) and ref.path != ""
      assert is_binary(ref.arn) and ref.arn != ""
    end

    refs
  end

  @doc """
  An unknown-but-valid environment name returns `{:ok, []}`, never an error —
  this boundary does not validate environment names against the tenant API.
  """
  def assert_list_secrets_on_unknown_environment_is_empty(impl) do
    assert {:ok, []} = impl.list_secrets(unique("unknown-environment"))
  end

  @doc """
  Revealing a missing key is `:not_found`, never a crash or a different kind.
  """
  def assert_get_secret_not_found(impl, environment) do
    assert {:error, %Error{kind: :not_found}} =
             impl.get_secret(environment, unique("missing-key"))
  end

  @doc """
  `locate_secret/2` returns a fully-formed `%SecretLocation{}` — `SEC-A02`'s
  copy affordances need a real path and ARN, never `nil`.
  """
  def assert_locate_secret_shape(impl, environment, key) do
    assert {:ok, %SecretLocation{path: path, arn: arn}} = impl.locate_secret(environment, key)
    assert is_binary(path) and path != ""
    assert is_binary(arn) and arn != ""
  end

  @doc """
  `list_environments/0` includes `shared` — a genuinely manageable bucket,
  addressable the same as any other (EN-4 Decision 1).
  """
  def assert_list_environments_includes_shared(impl) do
    assert {:ok, environments} = impl.list_environments()
    assert is_list(environments)
    assert "shared" in environments
    environments
  end

  @doc """
  `list_all_secrets/0` returns `%{environment:, secret:}` pairs, `secret`
  always a fully-formed `%SecretRef{}`.
  """
  def assert_list_all_secrets_shape(impl) do
    assert {:ok, all} = impl.list_all_secrets()
    assert is_list(all)

    for %{environment: environment, secret: %SecretRef{} = ref} <- all do
      assert is_binary(environment) and environment != ""
      assert is_binary(ref.key) and ref.key != ""
    end

    all
  end

  @doc """
  `health_check/0` reports reachable.
  """
  def assert_health_check(impl) do
    assert impl.health_check() == :ok
  end

  # -- Mutation assertions (Local only) -----------------------------------

  @doc """
  Create then get round-trips the exact value.
  """
  def assert_create_then_get_roundtrips(impl, environment, key, value) do
    assert {:ok, %SecretRef{key: ^key}} = impl.create_secret(environment, key, value)
    assert {:ok, %Secret{key: ^key, value: ^value}} = impl.get_secret(environment, key)
  end

  @doc """
  Creating an existing key is rejected, `SEC-A12`, never silently overwritten.
  """
  def assert_create_on_existing_key_conflicts(impl, environment, key, value) do
    assert {:ok, _ref} = impl.create_secret(environment, key, value)

    assert {:error, %Error{kind: :already_exists}} =
             impl.create_secret(environment, key, value)
  end

  @doc """
  Updating a missing key is rejected, never silently created.
  """
  def assert_update_on_missing_key_not_found(impl, environment, key, value) do
    assert {:error, %Error{kind: :not_found}} = impl.update_secret(environment, key, value)
  end

  @doc """
  Update then get round-trips the new value and bumps `last_modified`.
  """
  def assert_update_then_get_roundtrips_and_bumps_last_modified(
        impl,
        environment,
        key,
        initial,
        updated
      ) do
    assert {:ok, _ref} = impl.create_secret(environment, key, initial)
    assert {:ok, %Secret{last_modified: created_at}} = impl.get_secret(environment, key)

    assert {:ok, %SecretRef{last_modified: updated_at}} =
             impl.update_secret(environment, key, updated)

    assert {:ok, %Secret{value: ^updated}} = impl.get_secret(environment, key)

    assert DateTime.compare(updated_at, created_at) == :gt
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
