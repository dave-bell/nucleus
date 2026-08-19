defmodule Nucleus.Secrets.Store.ContractTest do
  @moduledoc """
  The same assertions against every implementation of the `:secrets` boundary.

  `Local` always runs, mutations included. `Aws` runs read-only assertions
  only, and only when `TEST_TENANT_ROLE_ARN` names a real cross-account role —
  tagged `:external`, excluded by default in `test_helper.exs`, so a fresh
  clone with no AWS access still goes green.

      TEST_TENANT_ROLE_ARN=arn:aws:iam::123456789012:role/nucleus-test \\
        AWS_REGION=us-east-1 mix test --include external

  Mutation assertions run against `Local` only — per ADR-0007, a test suite
  must never mutate a real tenant's parameters.
  """
  use ExUnit.Case, async: false

  alias Nucleus.Aws.CredentialCache
  alias Nucleus.Backend.Seed
  alias Nucleus.Secrets.Store.Aws
  alias Nucleus.Secrets.Store.Local
  alias NucleusTest.SecretsStoreContract, as: Contract

  describe "Nucleus.Secrets.Store.Local" do
    setup do
      on_exit(&Seed.reset/0)
      :ok
    end

    test "list_secrets/1 returns fully-formed SecretRefs" do
      Contract.assert_list_secrets_shape(Local, "prod")
    end

    test "list_secrets/1 on an unknown-but-valid environment is {:ok, []}" do
      Contract.assert_list_secrets_on_unknown_environment_is_empty(Local)
    end

    test "get_secret/2 on a missing key is :not_found" do
      Contract.assert_get_secret_not_found(Local, "prod")
    end

    test "locate_secret/2 returns a fully-formed SecretLocation" do
      Contract.assert_locate_secret_shape(Local, "prod", "DATABASE_URL")
    end

    test "list_environments/0 includes shared" do
      Contract.assert_list_environments_includes_shared(Local)
    end

    test "list_all_secrets/0 returns environment/secret pairs" do
      Contract.assert_list_all_secrets_shape(Local)
    end

    test "health_check/0 is :ok" do
      Contract.assert_health_check(Local)
    end

    test "create then get round-trips the exact value" do
      Contract.assert_create_then_get_roundtrips(Local, "prod", "CONTRACT_KEY", "s3cr3t-value")
    end

    test "create on an existing key is :already_exists" do
      Contract.assert_create_on_existing_key_conflicts(Local, "prod", "CONTRACT_DUP", "v1")
    end

    test "update on a missing key is :not_found" do
      Contract.assert_update_on_missing_key_not_found(Local, "prod", "CONTRACT_MISSING", "v1")
    end

    test "update then get round-trips the new value and bumps last_modified" do
      Contract.assert_update_then_get_roundtrips_and_bumps_last_modified(
        Local,
        "prod",
        "CONTRACT_UPDATE",
        "v1",
        "v2"
      )
    end
  end

  describe "Nucleus.Secrets.Store.Aws" do
    @describetag :external

    setup do
      role_arn =
        System.get_env("TEST_TENANT_ROLE_ARN") ||
          flunk("TEST_TENANT_ROLE_ARN must be set to run the external contract tests")

      region = System.get_env("AWS_REGION") || "us-east-1"
      cache_key = {role_arn, nil, "nucleus-secrets"}

      original_aws = Application.get_env(:nucleus, Aws)
      original_path = Application.get_env(:nucleus, Nucleus.Secrets.Path)

      Application.put_env(:nucleus, Aws, role_arn: role_arn, region: region, external_id: nil)

      Application.put_env(:nucleus, Nucleus.Secrets.Path,
        cluster_name: System.get_env("TEST_CLUSTER_NAME", "nucleus-test"),
        deployment_name: System.get_env("TEST_DEPLOYMENT_NAME", "nucleus-test")
      )

      CredentialCache.clear(cache_key)

      on_exit(fn ->
        Application.put_env(:nucleus, Aws, original_aws)
        Application.put_env(:nucleus, Nucleus.Secrets.Path, original_path)
        CredentialCache.clear(cache_key)
      end)

      :ok
    end

    test "list_secrets/1 returns fully-formed SecretRefs" do
      Contract.assert_list_secrets_shape(Aws, "shared")
    end

    test "list_secrets/1 on an unknown-but-valid environment is {:ok, []}" do
      Contract.assert_list_secrets_on_unknown_environment_is_empty(Aws)
    end

    test "get_secret/2 on a missing key is :not_found" do
      Contract.assert_get_secret_not_found(Aws, "shared")
    end

    test "list_environments/0 includes shared" do
      Contract.assert_list_environments_includes_shared(Aws)
    end

    test "list_all_secrets/0 returns environment/secret pairs" do
      Contract.assert_list_all_secrets_shape(Aws)
    end

    test "health_check/0 is :ok" do
      Contract.assert_health_check(Aws)
    end
  end
end
