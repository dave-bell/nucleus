defmodule Nucleus.M2M.Clients.ContractTest do
  @moduledoc """
  The same assertions against every implementation of the `:m2m` boundary.

  `Local` always runs, mutations included. `Cognito` runs read-only
  assertions only, and only when `TEST_COGNITO_ROLE_ARN` and
  `TEST_COGNITO_USER_POOL_ID` name a real, disposable test pool — tagged
  `:external`, excluded by default in `test_helper.exs`, so a fresh clone
  with no AWS access still goes green.

  Mutation assertions run against `Local` only — this suite must never create
  or rotate a real Cognito app client.
  """
  use ExUnit.Case, async: false

  alias Nucleus.Aws.CredentialCache
  alias Nucleus.Backend.Seed
  alias Nucleus.M2M.Clients.Cognito
  alias Nucleus.M2M.Clients.Local
  alias NucleusTest.M2MClientsContract, as: Contract

  @default_settings [token_validity_minutes: 15]

  describe "Nucleus.M2M.Clients.Local" do
    setup do
      on_exit(&Seed.reset/0)
      :ok
    end

    test "list_clients/0 returns fully-formed Clients, none carrying a secret" do
      Contract.assert_list_clients_shape(Local)
    end

    test "describe_client/1 on an unknown ID is :not_found" do
      Contract.assert_describe_client_not_found(Local)
    end

    test "describe_client/1 returns a fully-formed ClientDetail with no secret" do
      {:ok, [client | _]} = Local.list_clients()
      Contract.assert_describe_client_shape(Local, client.client_id)
    end

    test "health_check/0 is :ok" do
      Contract.assert_health_check(Local)
    end

    test "create_client/2 returns credentials with a non-empty secret" do
      Contract.assert_create_client_returns_credentials(
        Local,
        unique("contract-client"),
        @default_settings
      )
    end

    test "create_client/2 allows a duplicate name, with a distinct client_id" do
      Contract.assert_create_client_allows_duplicate_name(
        Local,
        unique("contract-dup"),
        @default_settings
      )
    end

    test "create_client/2 rejects an out-of-range token_validity_minutes" do
      Contract.assert_create_client_rejects_invalid_validity(Local, unique("contract-invalid"))
    end

    test "rotate_secret/1 returns a new secret for the same client_id" do
      Contract.assert_rotate_secret_roundtrips(
        Local,
        unique("contract-rotate"),
        @default_settings
      )
    end

    test "rotate_secret/1 on an unknown ID is :not_found" do
      Contract.assert_rotate_secret_not_found(Local)
    end
  end

  describe "Nucleus.M2M.Clients.Cognito" do
    @describetag :external

    setup do
      role_arn =
        System.get_env("TEST_COGNITO_ROLE_ARN") ||
          flunk("TEST_COGNITO_ROLE_ARN must be set to run the external contract tests")

      pool_id =
        System.get_env("TEST_COGNITO_USER_POOL_ID") ||
          flunk("TEST_COGNITO_USER_POOL_ID must be set to run the external contract tests")

      region = System.get_env("COGNITO_REGION") || "us-east-1"
      cache_key = {role_arn, nil, "nucleus-m2m"}

      original = Application.get_env(:nucleus, Cognito)

      Application.put_env(:nucleus, Cognito,
        role_arn: role_arn,
        region: region,
        external_id: nil,
        user_pool_id: pool_id
      )

      CredentialCache.clear(cache_key)

      on_exit(fn ->
        Application.put_env(:nucleus, Cognito, original)
        CredentialCache.clear(cache_key)
      end)

      :ok
    end

    test "list_clients/0 returns fully-formed Clients, none carrying a secret" do
      Contract.assert_list_clients_shape(Cognito)
    end

    test "describe_client/1 on an unknown ID is :not_found" do
      Contract.assert_describe_client_not_found(Cognito)
    end

    test "health_check/0 is :ok" do
      Contract.assert_health_check(Cognito)
    end
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
