defmodule Nucleus.NomadJobs.Local do
  @moduledoc """
  Nomad jobs served from `priv/backends/local_seed.json`.

  A real implementation of `Nucleus.NomadJobs`, not a test double — the same
  module serves `mix phx.server` in development and the test suite. A fresh
  clone needs no Nomad ACL token to exercise the `Applications` view at all.

  ## State lives in `Nucleus.Backend.Seed`, not a second `Agent`

  Reads go through `Seed.read/1`, keyed on this boundary's `"nomad_jobs"`
  section — the same reasoning `Nucleus.TenantApi.Local` and
  `Nucleus.M2M.Clients.Local` document for their own sections. This boundary
  has no mutation of any kind (see `Nucleus.NomadJobs`'s moduledoc), so
  `Seed.update/2` is never called here.

  ## The seed section's shape mirrors two real Nomad API calls, not one struct

  A list of `%{"stub" => ..., "detail" => ...}` entries — `"stub"` shaped
  like one element of `GET /v1/jobs`'s response, `"detail"` shaped like
  `GET /v1/job/:id`'s. `Nucleus.NomadJobs.Job.from_api/3` and `.child?/1` are
  the exact functions `Nucleus.NomadJobs.Http` calls against a real
  response, so a fixture here exercises the same translation logic a real
  Nomad job would — the same "seed mirrors the real shape" precedent
  `Nucleus.TenantApi.Local` sets by seeding `Environment.from_api_list/1`'s
  own input shape.

  ## The fixtures are deliberate

  | Entry | Exercises |
  |---|---|
  | `acme-api` | primary task selection: an authored prestart task first, an injected-shaped `connect-proxy-*` sidecar, image read from neither (Decision 3) |
  | `acme-ingress` | `Lifecycle == nil` selecting the one task on a Connect ingress gateway job, yielding its unresolved `${meta.connect.gateway_image}` reference |
  | `acme-nightly-report` + two children | a periodic parent; children carry a non-blank `ParentID` and never surface as their own rows (`APP-A01`) |
  | `acme-hourly-sync` | the modern `crons` block (`Periodic.Specs`), Decision 5's other branch |
  | `acme-batch-import` + two children | a parameterized/dispatch parent; `ParentID` filtering applies to dispatch children too (Decision 4), not periodic children only |
  | `acme-adhoc-export` | a parameterized parent with zero dispatches — renders as no-schedule, not periodic-shaped |
  | `acme-legacy-raw-exec` | no task has `Lifecycle == nil` — `image: nil` with `detail_error: nil`, a genuine absence, not a fetch failure |
  | `acme-worker-pending`, `acme-api`/`acme-nightly-report` (running), `acme-worker-dead` | one job per `status` value |

  ## Faults come first

  Every callback calls `Nucleus.Backend.Faults.maybe_fault/1` before doing
  anything else, so `LOCAL_FORCE_ERROR=unavailable` makes `APP-A07`'s error
  state testable without a real Nomad outage. This boundary has no per-row
  fault injection — that is `Nucleus.NomadJobs.Http`'s own contract test,
  against a stubbed transport, not a concern of the local implementation.
  """

  @behaviour Nucleus.NomadJobs

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Faults
  alias Nucleus.Backend.Seed
  alias Nucleus.NomadJobs
  alias Nucleus.NomadJobs.Job

  @impl NomadJobs
  def list_jobs(namespace) do
    with :ok <- Faults.maybe_fault(NomadJobs.boundary()),
         {:ok, entries} <- entries() do
      jobs =
        entries
        |> Enum.reject(&Job.child?(Map.get(&1, "stub", %{})))
        |> Enum.map(&Job.from_api(&1["stub"], &1["detail"], namespace))

      {:ok, jobs}
    end
  end

  @impl NomadJobs
  def health_check do
    with :ok <- Faults.maybe_fault(NomadJobs.boundary()),
         {:ok, _entries} <- entries() do
      :ok
    end
  end

  defp entries do
    case Seed.read(NomadJobs.boundary()) do
      list when is_list(list) ->
        {:ok, list}

      nil ->
        {:error,
         error(:not_configured, ~s(the backend seed has no "nomad_jobs" section), %{
           seed_path: Seed.default_path()
         })}

      other ->
        {:error,
         error(:not_configured, ~s(the seed's "nomad_jobs" section is not a list), %{
           section: inspect(other)
         })}
    end
  end

  defp error(kind, message, details) do
    Error.new(kind, NomadJobs.boundary(), message, details)
  end
end
