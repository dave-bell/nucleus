defmodule NucleusWeb.ApplicationsLive do
  @moduledoc """
  Lists the tenant's deployed applications (`APP-A01`), with an empty state
  (`APP-A06`), distinct error states (`APP-A07`), and no mutating affordance
  of any kind (`APP-A08`) — issue #58, APP-S1.

  ## Single module — no Index/Show split

  Unlike `NucleusWeb.M2MClientsLive`, there is no per-item detail route to
  justify `phx.gen.live`'s Index/Show split (`docs/adr/0018`): Applications
  is one screen, one table, no drill-down. `NucleusWeb.ApplicationsLive.States`
  is the only sibling module, mirroring `NucleusWeb.M2MClientsLive.States`.

  ## No URL params to gate — `mount/3`, not `handle_params/3`

  `/applications` carries no identifier, matching
  `NucleusWeb.M2MClientsLive.Index`'s own reasoning: nothing a `<.link
  patch={...}>` could change without a remount, so the one fetch happens in
  `mount/3` directly.

  ## One call to `Nucleus.NomadJobs.list/1`

  `list/1` already excludes periodic and dispatch children before returning
  (`Nucleus.NomadJobs.Job.child?/1`) — `APP-A01`'s periodic-collapsing
  requirement needs no work here beyond consuming what comes back. A
  LiveView-level test still asserts no seeded child ever renders its own
  row, so a future `Nucleus.NomadJobs` regression that starts leaking
  children is caught at the rendering boundary too, not only at EN-11's own
  context-level test.

  `Nucleus.NomadJobs.Local.list_jobs/1` returns entries in the seed file's
  own order, not sorted — this module sorts name-ascending with a
  case-insensitive tiebreak, matching `Nucleus.M2M.list/1`'s own
  `Enum.sort_by(&{String.downcase(&1.name), &1.name})`, for the same
  flakiness reasons EN-10's Cognito pagination and this feature's
  JSON-decoded map both lack a stable native order.

  ## Every outcome gets its own assign and DOM id

  `Nucleus.NomadJobs.list/1` can succeed or fail with any
  `Nucleus.Backend.Error.kinds/0` value — this `case` collapses them to
  three states via `NucleusWeb.ApplicationsLive.States`, mirroring
  `NucleusWeb.M2MClientsLive.Index` exactly (`docs/adr/0010`):

  | Outcome | `:status` | DOM id |
  |---|---|---|
  | `{:ok, jobs}` | `:ok` | `#applications-table` / `#applications-empty` |
  | `kind: :not_configured` | `:misconfigured` | `#applications-misconfigured` |
  | `kind: :unavailable` | `:unavailable` | `#applications-unavailable` |
  | `kind: :auth_expired` | `:auth_expired` | `#applications-auth-expired` |
  | anything else (`:not_found`, `:already_exists`, `:invalid` — none of
    which `list/1` has reason to return today) | `:unavailable` | `#applications-unavailable` |

  Every branch keeps `<Layouts.app>` intact (`#tenant-identifier` present)
  so the user can navigate away — `APP-A07`'s "rest of the shell remains
  usable".

  ## `stream/3`, plus a separate count assign

  Streams are not enumerable (`AGENTS.md`), so `:job_count` — set alongside
  the stream, from the same `Nucleus.NomadJobs.list/1` call, never
  recomputed separately — drives the empty-state branch (`APP-A06`). Unlike
  `NucleusWeb.M2MClientsLive.Index`'s create button, there is no affordance
  that must stay visible alongside the empty state, so the explicit
  `@job_count == 0` conditional is used for consistency with that module's
  established pattern rather than because anything here needs it.

  ## Row cells this ticket fills in, and the placeholders `APP-S2` (#59) replaces

  Every column's DOM id is fixed now, even the ones this ticket doesn't
  finish styling (`docs/adr/0010`, `docs/adr/0018`):

  | Column | This ticket | `APP-S2` (#59) adds |
  |---|---|---|
  | Name | full text | — |
  | Status | raw status text | colour distinction (`APP-A02`) |
  | Version | placeholder cell, DOM id fixed | explicit version text (`APP-A03`) |
  | Image | placeholder cell, DOM id fixed | image name:tag (`APP-A03`) |
  | Schedule | placeholder cell, DOM id fixed | cron text / explicit "no schedule" (`APP-A04`, `APP-A05`) |

  ## `APP-A08` — no mutating affordance anywhere

  No create button, no per-row edit/delete/restart/redeploy control, no
  "Actions" column. This is enforced one layer below the UI already —
  `Nucleus.NomadJobs` defines no create/update/delete callback of any kind
  — but the negative test here proves the template itself adds none either.

  `current_scope` and `environments`/`expanded_categories` come from the
  `:authenticated` `live_session`'s `on_mount` hooks (`NucleusWeb.ScopeHook`,
  `NucleusWeb.EnvironmentsHook`), same order as `NucleusWeb.M2MClientsLive.Index`
  — this module does not assign any of them itself.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.NomadJobs
  alias Nucleus.NomadJobs.Job
  alias NucleusWeb.ApplicationsLive.States

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:jobs, dom_id: &dom_id/1)
      |> stream(:jobs, [])
      |> fetch_jobs()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("retry", _params, socket) do
    {:noreply, fetch_jobs(socket)}
  end

  defp fetch_jobs(socket) do
    case NomadJobs.list(socket.assigns.current_scope) do
      {:ok, jobs} ->
        sorted = Enum.sort_by(jobs, &{String.downcase(&1.name), &1.name})

        socket
        |> assign(status: :ok, job_count: length(sorted))
        |> stream(:jobs, sorted, reset: true)

      {:error, %Error{kind: :not_configured}} ->
        assign(socket, status: :misconfigured, job_count: 0)

      {:error, %Error{kind: :auth_expired}} ->
        assign(socket, status: :auth_expired, job_count: 0)

      {:error, %Error{}} ->
        assign(socket, status: :unavailable, job_count: 0)
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      environments={@environments}
      expanded_categories={@expanded_categories}
    >
      <States.misconfigured :if={@status == :misconfigured} />
      <States.unavailable :if={@status == :unavailable} />
      <States.auth_expired :if={@status == :auth_expired} />

      <div :if={@status == :ok}>
        <h1 class="text-lg font-semibold pb-4">Applications</h1>

        <.empty_state
          :if={@job_count == 0}
          id="applications-empty"
          icon="hero-inbox"
          message="No jobs found in this namespace."
        />

        <div :if={@job_count > 0} id="applications-table">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Name</th>
                <th>Status</th>
                <th>Version</th>
                <th>Image</th>
                <th>Schedule</th>
              </tr>
            </thead>
            <tbody id="applications-table-body" phx-update="stream">
              <tr :for={{dom_id, job} <- @streams.jobs} id={dom_id} data-job-name={job.name}>
                <td class="font-medium">{job.name}</td>
                <td id={cell_id(job.name, "status")}>{job.status}</td>
                <td id={cell_id(job.name, "version")}></td>
                <td id={cell_id(job.name, "image")}></td>
                <td id={cell_id(job.name, "schedule")}></td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp dom_id(%Job{name: name}), do: "job-" <> name

  defp cell_id(name, column), do: "job-" <> name <> "-" <> column
end
