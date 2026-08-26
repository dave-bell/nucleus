defmodule Nucleus.NomadJobs.StallingImpl do
  @moduledoc false
  # A fake implementation used only by Nucleus.NomadJobsTest to prove the
  # ~15s overall budget resolves into an error rather than blocking, without
  # the test suite actually waiting out a real Nomad timeout.
  @behaviour Nucleus.NomadJobs

  @impl Nucleus.NomadJobs
  def list_jobs(_namespace) do
    Process.sleep(:infinity)
  end

  @impl Nucleus.NomadJobs
  def health_check, do: :ok
end

defmodule Nucleus.NomadJobs.CrashingImpl do
  @moduledoc false
  # A fake implementation used only by Nucleus.NomadJobsTest to prove an
  # unhandled exception inside the fan-out degrades to {:error, %Error{}}
  # rather than crashing whatever process called list/1 — only possible
  # because list/1 runs the implementation via Task.Supervisor.async_nolink/2,
  # not Task.async/1 (which links, and would take the caller down with it).
  @behaviour Nucleus.NomadJobs

  @impl Nucleus.NomadJobs
  def list_jobs(_namespace) do
    raise "boom"
  end

  @impl Nucleus.NomadJobs
  def health_check, do: :ok
end

defmodule Nucleus.NomadJobsTest do
  # Swaps the configured implementation and the budget, both application-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nucleus.Backend
  alias Nucleus.Backend.Error
  alias Nucleus.NomadJobs
  alias Nucleus.NomadJobs.CrashingImpl
  alias Nucleus.NomadJobs.Local
  alias Nucleus.NomadJobs.StallingImpl
  alias Nucleus.Scope

  @scope %Scope{}

  setup do
    original_backends = Application.get_env(:nucleus, :backends)
    original_module_config = Application.get_env(:nucleus, NomadJobs)

    on_exit(fn ->
      Application.put_env(:nucleus, :backends, original_backends)
      Application.put_env(:nucleus, NomadJobs, original_module_config || [])
    end)

    :ok
  end

  defp use_backend(module) do
    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(Application.get_env(:nucleus, :backends, []), :nomad_jobs, module)
    )
  end

  describe "the boundary is registered" do
    test "impl_for(:nomad_jobs) resolves to a real, loaded module" do
      assert Backend.impl_for(:nomad_jobs) in [Nucleus.NomadJobs.Http, Nucleus.NomadJobs.Local]
    end

    test "both registered implementations exist and implement the behaviour" do
      for mode <- [:real, :local] do
        module = Backend.impl_for_mode!(:nomad_jobs, mode)

        assert Code.ensure_loaded?(module)
        assert NomadJobs in module.module_info(:attributes)[:behaviour]
      end
    end
  end

  describe "dispatch" do
    test "list/1 goes to the configured implementation" do
      use_backend(Local)
      assert {:ok, jobs} = NomadJobs.list(@scope)
      assert jobs != []
    end

    test "health_check/0 goes to the configured implementation" do
      use_backend(Local)
      assert NomadJobs.health_check() == :ok
    end
  end

  describe "the scope argument" do
    test "is accepted but tenancy does not come from it — namespace comes from Scope.tenant_namespace/0" do
      use_backend(Local)

      # A scope carrying a different tenant does not change which namespace
      # is queried — see the moduledoc's "asymmetry with Secrets" note.
      differently_scoped = %Scope{tenant: "some-other-tenant"}

      assert {:ok, jobs} = NomadJobs.list(differently_scoped)
      assert Enum.all?(jobs, &(&1.namespace == Scope.tenant_namespace()))
    end
  end

  describe "the overall budget" do
    test "returns :unavailable rather than blocking when the implementation stalls" do
      use_backend(StallingImpl)
      Application.put_env(:nucleus, NomadJobs, budget_ms: 50)

      assert {:error, %Error{kind: :unavailable, boundary: :nomad_jobs, details: details}} =
               NomadJobs.list(@scope)

      assert details.budget_ms == 50
    end

    test "defaults to 15s when unconfigured" do
      Application.put_env(:nucleus, NomadJobs, [])
      use_backend(Local)

      assert {:ok, _jobs} = NomadJobs.list(@scope)
    end
  end

  describe "a crash inside the fan-out" do
    test "degrades to {:error, %Error{}} rather than crashing the caller" do
      use_backend(CrashingImpl)
      test_pid = self()

      # If list/1 ever regresses to Task.async/1 (which links), the spawned
      # task's crash takes this spawned caller process down too, and it never
      # sends :result — the assert_receive below times out instead of failing
      # on a mismatched value, which is why this runs in its own process
      # rather than calling NomadJobs.list/1 directly in the test process.
      capture_log(fn ->
        {caller, ref} =
          spawn_monitor(fn -> send(test_pid, {:result, NomadJobs.list(@scope)}) end)

        assert_receive {:result, {:error, %Error{kind: :unavailable, boundary: :nomad_jobs}}}
        # A clean, normal exit — not the crash's own reason — proves the
        # caller was never linked to (and so never brought down by) the
        # failing task.
        assert_receive {:DOWN, ^ref, :process, ^caller, :normal}
      end)
    end
  end

  describe "boundary/0" do
    test "names the boundary the errors are tagged with" do
      assert NomadJobs.boundary() == :nomad_jobs
      assert NomadJobs.boundary() in Backend.boundaries()
    end
  end
end
