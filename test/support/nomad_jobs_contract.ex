defmodule NucleusTest.NomadJobsContract do
  @moduledoc """
  Assertions every `Nucleus.NomadJobs` implementation must satisfy.

  Plain functions, not a `__using__` macro — same pattern as
  `NucleusTest.TenantApiContract` and `NucleusTest.M2MClientsContract`, so the
  assertions are literally shared between `Local` and `Http` rather than
  generated twice.
  """

  import ExUnit.Assertions

  alias Nucleus.NomadJobs.Job

  @doc """
  Asserts `impl` returns a usable job list for `namespace`.
  """
  def assert_lists_jobs(impl, namespace) do
    assert {:ok, jobs} = impl.list_jobs(namespace)
    assert is_list(jobs)

    jobs
  end

  @doc """
  Asserts every element is a fully-formed `%Job{}`, with the `detail_error`
  field's own invariant held: non-nil means `version`, `image`, and `cron`
  are all `nil` (Decision 6, `docs/adr/0022-nomad-jobs-adapter.md`).
  """
  def assert_element_shape(impl, namespace) do
    for job <- assert_lists_jobs(impl, namespace) do
      assert %Job{} = job

      assert is_binary(job.name) and job.name != "", "name must be a non-blank binary"
      assert is_binary(job.status) and job.status != "", "status must be a non-blank binary"
      assert job.namespace == namespace
      assert is_boolean(job.periodic?), "periodic? must always be a boolean"

      case job.detail_error do
        nil ->
          assert is_nil(job.version) or is_integer(job.version)
          assert is_nil(job.image) or is_binary(job.image)
          assert is_nil(job.cron) or is_binary(job.cron)

        kind ->
          assert is_atom(kind)
          assert is_nil(job.version), "version must be nil when detail_error is set"
          assert is_nil(job.image), "image must be nil when detail_error is set"
          assert is_nil(job.cron), "cron must be nil when detail_error is set"
      end
    end
  end

  @doc """
  Asserts a non-periodic job's `cron` is `nil`, never a blank string
  (`APP-A05`).
  """
  def assert_non_periodic_has_no_cron(impl, namespace) do
    for %Job{periodic?: false} = job <- assert_lists_jobs(impl, namespace) do
      assert is_nil(job.cron), "a non-periodic job's cron must be nil, got: #{inspect(job.cron)}"
    end
  end

  @doc """
  Asserts `impl` reports itself reachable.
  """
  def assert_health_check(impl) do
    assert impl.health_check() == :ok
  end
end
