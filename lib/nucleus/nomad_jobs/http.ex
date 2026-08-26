defmodule Nucleus.NomadJobs.Http do
  @moduledoc """
  Nomad jobs over HTTP, using `Nucleus.Nomad.Transport`.

  ## Two calls per parent job — unavoidable, not a design choice to litigate

  `GET /v1/jobs?namespace=<namespace>` returns a `JobListStub` per job: no
  container image, no `Job.Version`, and `Periodic` as a boolean rather than
  the cron object. `ADR-0006`'s (wiki) accepted decision already grants both
  `list-jobs` and `read-job` in the deployment namespace and anticipates this
  fan-out directly. `Task.async_stream/3` with `max_concurrency: 10,
  timeout: :infinity` — the same construction EN-10/#33's
  `Nucleus.M2M.Clients.Cognito.list_clients/0` uses for its own
  list-then-describe fan-out. `timeout: :infinity` is correct on the stream
  itself: the per-request `receive_timeout` (`Nucleus.Nomad.Transport`)
  terminates a stalled call, and the overall budget belongs to
  `Nucleus.NomadJobs.list/1`, not this module or the stream.

  ## Children are filtered before the fan-out, not after

  `ParentID` is present in the **list** stub, so `Nucleus.NomadJobs.Job.child?/1`
  runs against the raw stub before any detail call — periodic and
  parameterized/dispatch children alike (Decision 4) never cost a
  `GET /v1/job/:id`.

  ## A per-job detail failure degrades that one row

  `Nucleus.NomadJobs.Job.degraded/3`, not a failure of the whole list. A
  `rescue` around each fan-out task additionally catches an unexpected
  response shape (a future Nomad API change) exactly like a classified
  `Nucleus.Backend.Error` does, mirroring
  `Nucleus.M2M.Clients.Cognito.describe_for_list/3`'s own `rescue` — logging
  only the exception's module, never its message, since a `MatchError`
  carries the full unexpected term.

  See `docs/adr/0022-nomad-jobs-adapter.md` for the full decision record.
  """

  @behaviour Nucleus.NomadJobs

  require Logger

  alias Nucleus.Backend.Error
  alias Nucleus.Nomad.Transport
  alias Nucleus.NomadJobs
  alias Nucleus.NomadJobs.Job

  @max_concurrency 10

  @impl NomadJobs
  def list_jobs(namespace) when is_binary(namespace) do
    with {:ok, stubs} <- fetch_list(namespace) do
      jobs =
        stubs
        |> Enum.reject(&Job.child?/1)
        |> fan_out(namespace)

      {:ok, jobs}
    end
  end

  @impl NomadJobs
  def health_check do
    # Reachability, not permission — the same reasoning
    # Nucleus.TenantApi.Http.health_check/0 states. An auth failure still
    # means Nomad answered; only an unreachable or errored Nomad is unhealthy.
    case fetch_list(Nucleus.Scope.tenant_namespace()) do
      {:ok, _stubs} -> :ok
      {:error, %Error{kind: :auth_expired}} -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp fetch_list(namespace) do
    case Transport.request(:get, "/v1/jobs",
           query: [namespace: namespace],
           boundary: NomadJobs.boundary()
         ) do
      {:ok, stubs} when is_list(stubs) ->
        {:ok, stubs}

      {:ok, _other} ->
        {:error, error(:unavailable, "nomad returned an unexpected shape for /v1/jobs")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp fan_out(stubs, namespace) do
    stubs
    |> Task.async_stream(&build_job(&1, namespace),
      max_concurrency: @max_concurrency,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, job} -> job end)
  end

  defp build_job(%{"ID" => id} = stub, namespace) do
    case fetch_detail(id, namespace) do
      {:ok, detail} -> Job.from_api(stub, detail, namespace)
      {:error, %Error{kind: kind}} -> Job.degraded(stub, namespace, kind)
    end
  rescue
    error ->
      Logger.warning(
        "nomad_jobs detail fan-out unexpected failure job_id=#{id} " <>
          "exception=#{inspect(error.__struct__)}"
      )

      Job.degraded(stub, namespace, :unavailable)
  end

  defp fetch_detail(job_id, namespace) do
    path = "/v1/job/" <> URI.encode(job_id)

    case Transport.request(:get, path,
           query: [namespace: namespace],
           boundary: NomadJobs.boundary()
         ) do
      {:ok, %{} = detail} ->
        {:ok, detail}

      {:ok, _other} ->
        {:error, error(:unavailable, "nomad returned an unexpected shape for /v1/job")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp error(kind, message, details \\ %{}) do
    Error.new(kind, NomadJobs.boundary(), message, details)
  end
end
