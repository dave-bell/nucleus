defmodule Nucleus.BackendCaseTest do
  @moduledoc """
  Self-tests for `Nucleus.BackendCase`. Relied on by every SEC ticket's own
  test plan, so a silent false-pass here corrupts everything downstream —
  see EN-8 (issue #8).

  Mutates `Nucleus.Backend.Seed` (globally-named) and the `LOCAL_FORCE_ERROR`
  environment variable (node-wide), so this file runs `async: false` — see
  `Nucleus.BackendCase`'s own moduledoc on why that is not optional here.
  """

  use Nucleus.BackendCase, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Secrets.Store
  alias Nucleus.TenantApi

  @tag :unit
  test "seed_secret writes a secret the local secrets store can read back" do
    seed_secret("prod", "BACKEND_CASE_TEST_KEY", "shh")

    assert {:ok, secret} = Store.get_secret("prod", "BACKEND_CASE_TEST_KEY")
    assert secret.value == "shh"
  end

  @tag :unit
  test "the previous test's seeded secret does not leak into this one" do
    assert {:error, %Error{kind: :not_found}} =
             Store.get_secret("prod", "BACKEND_CASE_TEST_KEY")
  end

  @tag :unit
  test "seed_environment appends an environment the local tenant API lists" do
    seed_environment(%{"shortName" => "backend-case-test-env", "label" => "Backend Case Test"})

    assert {:ok, environments} = TenantApi.list_environments(nil)
    assert Enum.any?(environments, &(&1.short_name == "backend-case-test-env"))
  end

  @tag :unit
  test "the previous test's seeded environment does not leak into this one" do
    assert {:ok, environments} = TenantApi.list_environments(nil)
    refute Enum.any?(environments, &(&1.short_name == "backend-case-test-env"))
  end

  @tag :unit
  test "force_error makes the next local call fail with the given kind" do
    force_error(:secrets, :unavailable)

    assert {:error, %Error{kind: :unavailable}} = Store.get_secret("prod", "DATABASE_URL")
  end

  @tag :unit
  test "a fault armed by the previous test does not leak into this one" do
    assert {:ok, _secret} = Store.get_secret("prod", "DATABASE_URL")
  end

  @tag :unit
  test "clear_faults removes a fault armed by force_error/2 within the same test" do
    force_error(:secrets, :unavailable)
    clear_faults()

    assert {:ok, _secret} = Store.get_secret("prod", "DATABASE_URL")
  end

  @tag :unit
  test "force_error raises on an unknown Nucleus.Backend.Error kind" do
    assert_raise ArgumentError, fn -> force_error(:secrets, :teapot) end
  end
end
