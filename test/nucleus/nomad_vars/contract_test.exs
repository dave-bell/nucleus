defmodule Nucleus.NomadVars.ContractTest do
  @moduledoc """
  The same assertions against every implementation of the `:nomad_vars`
  boundary.

  `Local` always runs, mutations included. `Http` runs read-only assertions
  only, and only when `TEST_NOMAD_ADDR` names a real Nomad cluster — tagged
  `:external` and excluded by default in `test_helper.exs`, so a fresh clone
  with no credentials still goes green.

      TEST_NOMAD_ADDR=https://nomad.example.com TEST_NOMAD_TOKEN=... \\
        mix test --include external

  Mutation assertions run against `Local` only — a test suite must never
  write to a real tenant's Nomad Variables.
  """
  use ExUnit.Case, async: false

  alias Nucleus.Backend.Seed
  alias Nucleus.NomadVars.Store.Http
  alias Nucleus.NomadVars.Store.Local
  alias NucleusTest.NomadVarsContract, as: Contract

  describe "Nucleus.NomadVars.Store.Local" do
    setup do
      on_exit(&Seed.reset/0)
      :ok
    end

    test "read/0 returns a fully-formed VariableSet" do
      Contract.assert_reads_variable_set(Local)
    end

    test "write/2 replaces items and bumps the modify index" do
      Contract.assert_write_updates_items(Local, %{"description" => "updated via contract test"})
    end

    test "write/2 against a stale modify index is :conflict" do
      Contract.assert_write_conflict_on_stale_index(Local, %{"description" => "should not apply"})
    end

    test "health_check/0 returns :ok" do
      Contract.assert_health_check(Local)
    end
  end

  describe "Nucleus.NomadVars.Store.Http" do
    @describetag :external

    setup do
      base_url =
        System.get_env("TEST_NOMAD_ADDR") ||
          flunk("TEST_NOMAD_ADDR must be set to run the external contract tests")

      original = Application.get_env(:nucleus, Nucleus.Nomad.Transport)

      Application.put_env(:nucleus, Nucleus.Nomad.Transport,
        base_url: base_url,
        token: System.get_env("TEST_NOMAD_TOKEN"),
        connect_timeout_ms: 5_000,
        receive_timeout_ms: 10_000
      )

      on_exit(fn -> Application.put_env(:nucleus, Nucleus.Nomad.Transport, original) end)
      :ok
    end

    test "read/0 returns a fully-formed VariableSet" do
      Contract.assert_reads_variable_set(Http)
    end

    test "health_check/0 returns :ok" do
      Contract.assert_health_check(Http)
    end
  end
end
