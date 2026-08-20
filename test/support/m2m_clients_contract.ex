defmodule NucleusTest.M2MClientsContract do
  @moduledoc """
  Assertions every `Nucleus.M2M.Clients` implementation must satisfy.

  Plain functions, not a `__using__` macro — same pattern as
  `NucleusTest.SecretsStoreContract`, so the assertions are literally shared
  between `Local` and `Cognito` rather than generated twice.

  Mutation assertions here are called against `Local` from
  `test/nucleus/m2m/clients/contract_test.exs` unconditionally, and against
  `Cognito` only under `@describetag :external` against a real, disposable
  test pool — this suite must never mutate a real tenant's user pool clients
  otherwise.
  """

  import ExUnit.Assertions

  alias Nucleus.Backend.Error
  alias Nucleus.M2M.Client
  alias Nucleus.M2M.ClientCredentials
  alias Nucleus.M2M.ClientDetail

  # -- Read assertions ---------------------------------------------------

  @doc """
  Every element of `impl.list_clients()` is a fully-formed `%Client{}`, and
  none carries a `:client_secret` key — the structural guard `M2M-A01`
  depends on, asserted at the contract level so both implementations are
  held to it.
  """
  def assert_list_clients_shape(impl) do
    assert {:ok, clients} = impl.list_clients()
    assert is_list(clients)

    for client <- clients do
      assert %Client{} = client
      assert is_binary(client.client_id) and client.client_id != ""
      assert is_binary(client.client_name) and client.client_name != ""
      refute Map.has_key?(client, :client_secret)
    end

    clients
  end

  @doc """
  `describe_client/1` on an unknown-but-well-formed client ID is `:not_found`,
  never a crash or a different kind.
  """
  def assert_describe_client_not_found(impl) do
    assert {:error, %Error{kind: :not_found}} = impl.describe_client(unique("missing-client"))
  end

  @doc """
  `describe_client/1` returns a fully-formed `%ClientDetail{}` for `client_id`,
  with no `:client_secret` key — the same structural guard as
  `assert_list_clients_shape/1`, for the detail view this time.
  """
  def assert_describe_client_shape(impl, client_id) do
    assert {:ok, %ClientDetail{} = detail} = impl.describe_client(client_id)
    assert detail.client_id == client_id
    assert is_binary(detail.client_name) and detail.client_name != ""
    assert is_binary(detail.scope)
    assert is_integer(detail.token_validity_seconds) and detail.token_validity_seconds > 0
    refute Map.has_key?(detail, :client_secret)
    detail
  end

  @doc """
  `health_check/0` reports reachable.
  """
  def assert_health_check(impl) do
    assert impl.health_check() == :ok
  end

  # -- Mutation assertions (Local only, or :external against a disposable pool) -

  @doc """
  `create_client/2` returns `ClientCredentials` with a non-empty secret.
  """
  def assert_create_client_returns_credentials(impl, client_name, settings) do
    assert {:ok, %ClientCredentials{} = credentials} = impl.create_client(client_name, settings)
    assert credentials.client_name == client_name
    assert is_binary(credentials.client_id) and credentials.client_id != ""
    assert is_binary(credentials.client_secret) and credentials.client_secret != ""
    credentials
  end

  @doc """
  Cognito does not require `client_name` to be unique
  ([decision](https://github.com/dave-bell/nucleus/issues/33#issuecomment-5350191153)
  — `M2M-A09` removed): a second `create_client/2` call with the same name
  succeeds too, and gets its own distinct `client_id`.
  """
  def assert_create_client_allows_duplicate_name(impl, client_name, settings) do
    assert {:ok, first} = impl.create_client(client_name, settings)
    assert {:ok, second} = impl.create_client(client_name, settings)
    refute first.client_id == second.client_id
  end

  @doc """
  `create_client/2` rejects a `token_validity_minutes` outside 5..60 with
  `:invalid` — the structural guard independent of any form validation.
  """
  def assert_create_client_rejects_invalid_validity(impl, client_name) do
    assert {:error, %Error{kind: :invalid}} =
             impl.create_client(client_name, token_validity_minutes: 4)

    assert {:error, %Error{kind: :invalid}} =
             impl.create_client(client_name, token_validity_minutes: 61)
  end

  @doc """
  `rotate_secret/1` returns a `ClientCredentials` whose `client_id` equals the
  input and whose secret differs from the one `create_client/2` returned.
  """
  def assert_rotate_secret_roundtrips(impl, client_name, settings) do
    assert {:ok, created} = impl.create_client(client_name, settings)
    assert {:ok, rotated} = impl.rotate_secret(created.client_id)

    assert rotated.client_id == created.client_id
    refute rotated.client_secret == created.client_secret

    {created, rotated}
  end

  @doc """
  `rotate_secret/1` on an unknown client ID is `:not_found`.
  """
  def assert_rotate_secret_not_found(impl) do
    assert {:error, %Error{kind: :not_found}} = impl.rotate_secret(unique("missing-client"))
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
