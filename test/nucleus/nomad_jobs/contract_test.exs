defmodule Nucleus.NomadJobs.ContractTest do
  @moduledoc """
  The same assertions against every implementation of the `:nomad_jobs`
  boundary.

  `Local` always runs. `Http` runs only when `TEST_NOMAD_ADDR` names a real
  Nomad cluster — tagged `:external` and excluded by default in
  `test_helper.exs`, so a fresh clone with no credentials still goes green.

      TEST_NOMAD_ADDR=https://nomad.example.com TEST_NOMAD_TOKEN=... \\
        mix test --include external

  """
  use ExUnit.Case, async: false

  alias Nucleus.Backend.Seed
  alias Nucleus.NomadJobs.Http
  alias Nucleus.NomadJobs.Local
  alias NucleusTest.NomadJobsContract, as: Contract

  @namespace "local"

  describe "Nucleus.NomadJobs.Local" do
    setup do
      on_exit(&Seed.reset/0)
      :ok
    end

    test "returns a list of jobs" do
      Contract.assert_lists_jobs(Local, @namespace)
    end

    test "every element is a fully-formed Job, with detail_error's invariant held" do
      Contract.assert_element_shape(Local, @namespace)
    end

    test "a non-periodic job's cron is nil, never a blank string" do
      Contract.assert_non_periodic_has_no_cron(Local, @namespace)
    end

    test "health_check/0 returns :ok" do
      Contract.assert_health_check(Local)
    end

    test "child jobs never surface as their own rows" do
      {:ok, jobs} = Local.list_jobs(@namespace)
      names = Enum.map(jobs, & &1.name)

      refute Enum.any?(names, &String.contains?(&1, "/periodic-"))
      refute Enum.any?(names, &String.contains?(&1, "/dispatch-"))
    end
  end

  describe "Nucleus.NomadJobs.Http" do
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

    test "returns a list of jobs" do
      Contract.assert_lists_jobs(Http, @namespace)
    end

    test "every element is a fully-formed Job, with detail_error's invariant held" do
      Contract.assert_element_shape(Http, @namespace)
    end

    test "health_check/0 returns :ok" do
      Contract.assert_health_check(Http)
    end
  end
end
