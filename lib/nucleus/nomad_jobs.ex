defmodule Nucleus.NomadJobs do
  @moduledoc """
  The boundary to Nomad job data for the tenant's `Applications` view
  (`docs/requirements/Applications.md`) — read-only visibility into what is
  actually deployed, never a way to change it.

  Two implementations, selected per boundary by `NOMAD_JOBS_BACKEND` — see
  `Nucleus.Backend`:

  | Mode | Module | |
  |---|---|---|
  | `real` | `Nucleus.NomadJobs.Http` | `Nucleus.Nomad.Transport` against the tenant's Nomad cluster |
  | `local` | `Nucleus.NomadJobs.Local` | `priv/backends/local_seed.json` |

  Named `:nomad_jobs`, not `:nomad` — deliberately diverging from wiki
  `ADR-0007`, which names a single `NOMAD_BACKEND`. Job **reads** (this
  boundary) and Nomad *Variables* (a future `:nomad_vars` boundary for Data
  Export configuration, read+write) are different capabilities with
  different access levels; collapsing them into one switch would put a write
  callback on the same boundary as `APP-A08`'s read-only guarantee. See
  `docs/adr/0022-nomad-jobs-adapter.md`, Decision 7.

  ## Call through this module, not an implementation

  `list/1` and `health_check/0` resolve the implementation on every call,
  through `Nucleus.Backend.impl_for/1`. Nothing outside this module should
  name `Http` or `Local`.

  ## No create, update, or delete callback of any kind

  This boundary is read-only **by construction**, in the terms
  `Nucleus.Secrets.Store` and `Nucleus.M2M.Clients` use for their own
  omissions (rotation aside, in M2M's case). `APP-A08` depends on this being
  true one layer below the UI, not merely enforced by a LiveView template
  choosing not to render a button.

  ## Emits no audit event

  `Applications.md`'s audit table is empty by design: "Viewing deployed
  application status is not a sensitive read." Matches the omission
  `Nucleus.M2M.list/1` documents for client listing.

  ## `list/1` takes a `Scope`, but tenancy does not come from it

  Matches `Nucleus.M2M.list/1`'s signature — `scope` is accepted for
  call-site symmetry with every other context function, not read here for
  tenancy. Nomad, like Cognito, has no per-request environment or tenant
  switch: one cluster per deployment, no runtime tenant switching
  (`docs/requirements/Platform-Operations.md`). The namespace comes from
  `Nucleus.Scope.tenant_namespace/0` (deployment config) — the same source
  `Nucleus.M2M.Clients.Cognito` reads for its own tenant-scoped OAuth scope.
  See `Nucleus.M2M`'s moduledoc, "Note the asymmetry with Secrets", for the
  fuller reasoning this borrows.

  ## The intended call site is a `Task`, not the LiveView process

  `APP-S1` (#58) mounts immediately with a loading state and runs this call
  off the LiveView process (Decision 8). `list/1` is safe to call from
  anywhere — no process-dictionary state, no `self()` assumption — but this
  is the only intended call site, which is why the budget below exists: it
  guarantees the eventual `Task` result resolves into something rather than
  hanging.

  ## The ~15s overall budget

  The detail fan-out (`Nucleus.NomadJobs.Http`) runs
  `Task.async_stream(max_concurrency: 10, timeout: :infinity)` against every
  parent job — the per-request `receive_timeout` (10s,
  `Nucleus.Nomad.Transport`) is what terminates one stalled call, not the
  stream's own timer. But nothing bounds *all the waves* that concurrency
  produces against a namespace with many jobs, so `list/1` wraps the whole
  call in its own budget and returns `{:error, %Error{kind: :unavailable}}`
  if it is exceeded — `APP-A07`'s error state is always reachable within a
  bounded time, never an indefinite spinner. See
  `docs/adr/0022-nomad-jobs-adapter.md`, Decision 8.

  The budget defaults to 15s and is configurable via `config :nucleus,
  Nucleus.NomadJobs, budget_ms: ...` — a fixed module attribute would force a
  stalled-detail test to actually wait 15 real seconds to exercise this
  branch.
  ## A crash inside the fan-out must not take the caller down with it

  `list/1` runs the implementation through `Task.Supervisor.async_nolink/2`
  (`Nucleus.TaskSupervisor`, `lib/nucleus/application.ex`), never
  `Task.async/1`. `Task.async/1` **links** the spawned process to the
  caller — an unhandled exception anywhere in the fan-out (not just a
  classified `Nucleus.Backend.Error`, which `Nucleus.NomadJobs.Http`'s own
  per-row `rescue` already degrades) would propagate the exit signal to
  whatever process called `list/1` and kill it too, before the `Task.yield/2`
  logic below ever ran. `async_nolink/2` is what makes the `{:exit, reason}`
  branch reachable at all, and what keeps the ~15s budget's guarantee — "an
  error tuple, never a crash" — true for the caller as well as for `list/1`
  itself.
  """

  alias Nucleus.Backend
  alias Nucleus.Backend.Error
  alias Nucleus.NomadJobs.Job
  alias Nucleus.Scope

  @boundary :nomad_jobs
  @budget_ms 15_000
  @task_supervisor Nucleus.TaskSupervisor

  @doc """
  Every parent job in `namespace`'s Nomad namespace (`APP-A01`).

  Child jobs — periodic and parameterized/dispatch alike — must already be
  excluded by the implementation before returning; see
  `Nucleus.NomadJobs.Job.child?/1`.

  A per-job detail-fetch failure degrades that one row (`Job.detail_error`
  set, `version`/`image`/`cron` all `nil`) rather than failing the whole
  list — only a failure of the list call itself does that.
  """
  @callback list_jobs(namespace :: String.t()) :: {:ok, [Job.t()]} | {:error, Error.t()}

  @doc """
  Whether this boundary can reach the system behind it.
  """
  @callback health_check() :: :ok | {:error, Error.t()}

  @doc """
  The boundary name, for `Nucleus.Backend` and error construction.
  """
  @spec boundary() :: atom()
  def boundary, do: @boundary

  @doc """
  Every deployed application, through the configured implementation, bounded
  to a ~15s overall budget.

  See the module doc for why `scope` is accepted but not read for tenancy,
  why the budget lives here rather than in the transport or the
  implementation, and why the fan-out runs unlinked from the caller.
  """
  @spec list(Scope.t()) :: {:ok, [Job.t()]} | {:error, Error.t()}
  def list(%Scope{} = _scope) do
    namespace = Scope.tenant_namespace()
    budget_ms = budget_ms()
    task = Task.Supervisor.async_nolink(@task_supervisor, fn -> impl().list_jobs(namespace) end)

    case Task.yield(task, budget_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error,
         Error.new(:unavailable, @boundary, "the nomad jobs fan-out crashed", %{
           reason: inspect(reason)
         })}

      nil ->
        {:error,
         Error.new(
           :unavailable,
           @boundary,
           "nomad did not answer within the overall budget",
           %{budget_ms: budget_ms}
         )}
    end
  end

  @doc """
  Checks the configured implementation can reach Nomad.
  """
  @spec health_check() :: :ok | {:error, Error.t()}
  def health_check, do: impl().health_check()

  defp budget_ms do
    Application.get_env(:nucleus, __MODULE__, []) |> Keyword.get(:budget_ms, @budget_ms)
  end

  defp impl, do: Backend.impl_for(@boundary)
end
