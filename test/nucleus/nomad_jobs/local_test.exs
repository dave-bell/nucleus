defmodule Nucleus.NomadJobs.LocalTest do
  # Fault injection is read from the OS environment, which is global to the node.
  use ExUnit.Case, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Seed
  alias Nucleus.NomadJobs.Job
  alias Nucleus.NomadJobs.Local

  @namespace "local"

  setup do
    # The seed owner is mutable and outlives any one test.
    on_exit(&Seed.reset/0)
    :ok
  end

  defp force_error(kind) do
    System.put_env("LOCAL_FORCE_ERROR", kind)
    on_exit(fn -> System.delete_env("LOCAL_FORCE_ERROR") end)
  end

  defp job!(name) do
    assert {:ok, jobs} = Local.list_jobs(@namespace)
    assert job = Enum.find(jobs, &(&1.name == name))
    job
  end

  describe "the seeded fixtures" do
    test "children never surface as their own rows — periodic and dispatch alike" do
      assert {:ok, jobs} = Local.list_jobs(@namespace)
      names = Enum.map(jobs, & &1.name)

      refute "acme-nightly-report/periodic-1755000000" in names
      refute "acme-nightly-report/periodic-1755086400" in names
      refute "acme-batch-import/dispatch-1755000111" in names
      refute "acme-batch-import/dispatch-1755000222" in names

      assert "acme-nightly-report" in names
      assert "acme-batch-import" in names
    end

    test "the primary task's image is selected over a leading prestart task and an injected sidecar" do
      job = job!("acme-api")

      assert job.image == "registry.example.com/acme/api:v1.4.0"
      assert job.version == 7
    end

    test "the ingress gateway job's unresolved template reference passes through as-is" do
      job = job!("acme-ingress")

      assert job.image == "${meta.connect.gateway_image}"
    end

    test "a periodic job authored with the legacy cron block reads Periodic.Spec" do
      job = job!("acme-nightly-report")

      assert job.periodic? == true
      assert job.cron == "0 3 * * *"
    end

    test "a periodic job authored with the modern crons block reads Periodic.Specs" do
      job = job!("acme-hourly-sync")

      assert job.periodic? == true
      assert job.cron == "0 * * * *"
    end

    test "a parameterized parent with zero dispatches renders as no-schedule" do
      job = job!("acme-adhoc-export")

      assert job.periodic? == false
      assert job.cron == nil
    end

    test "a job with no qualifying task has image: nil and detail_error: nil — a real absence" do
      job = job!("acme-legacy-raw-exec")

      assert job.image == nil
      assert job.detail_error == nil
    end

    test "one job of each status value is present" do
      assert {:ok, jobs} = Local.list_jobs(@namespace)
      statuses = jobs |> Enum.map(& &1.status) |> Enum.uniq() |> Enum.sort()

      assert statuses == ["dead", "pending", "running"]
    end
  end

  describe "the shared translation" do
    test "every element is a fully-formed Job struct" do
      assert {:ok, jobs} = Local.list_jobs(@namespace)

      for job <- jobs do
        assert %Job{} = job
        assert is_binary(job.name) and job.name != ""
        assert job.namespace == @namespace
        assert is_boolean(job.periodic?)
        assert job.detail_error == nil
      end
    end
  end

  describe "fault injection" do
    test "LOCAL_FORCE_ERROR=unavailable is the hook APP-A07 uses for the error state" do
      force_error("unavailable")

      assert {:error, %Error{kind: :unavailable, boundary: :nomad_jobs}} =
               Local.list_jobs(@namespace)
    end

    test "applies to health_check/0 as well" do
      force_error("unavailable")

      assert {:error, %Error{kind: :unavailable}} = Local.health_check()
    end

    test "an unparseable value raises rather than passing silently" do
      force_error("teapot")

      assert_raise ArgumentError, fn -> Local.list_jobs(@namespace) end
    end
  end

  describe "health_check/0" do
    test "is :ok when the seed is readable" do
      assert Local.health_check() == :ok
    end
  end

  describe "a broken seed section" do
    test "reads as :not_configured, not :unavailable — a bad file is not an unreachable cluster" do
      Seed.write(:nomad_jobs, %{"not" => "a list"})

      assert {:error, %Error{kind: :not_configured}} = Local.list_jobs(@namespace)
    end

    test "reads as :not_configured when the section is absent" do
      Seed.write(:nomad_jobs, nil)

      assert {:error, %Error{kind: :not_configured}} = Local.list_jobs(@namespace)
    end

    test "fails health_check/0" do
      Seed.write(:nomad_jobs, nil)

      assert {:error, %Error{kind: :not_configured}} = Local.health_check()
    end
  end
end
