defmodule NucleusWeb.DataExportLive.JobStates do
  @moduledoc """
  The Data Export deployment status panel's own failure state (`DEX-A02`,
  issue #77, DEX-S5) — a second sibling module alongside
  `NucleusWeb.DataExportLive.States`, not an addition to it, because the two
  cover different boundaries: `States` is entirely about `:nomad_vars` (the
  configuration table), this module is entirely about `:nomad_jobs` (the
  deployment status panel). Mixing them into one module would blur which
  boundary a given state describes.

  Unlike `NucleusWeb.ApplicationsLive.States`/`NucleusWeb.DataExportLive.States`,
  which give every `Nucleus.Backend.Error.kinds/0` value its own DOM id, this
  panel collapses every negative outcome — the job missing from
  `Nucleus.NomadJobs.list/1`'s result (folded into
  `Nucleus.Backend.Error.kind() :not_found`, per this ticket's own decision:
  favour the existing `Error.kind()` vocabulary over a bespoke
  `{:not_found}` tuple) and every other `Error.kind()` the list call itself
  can return — into one `#data-export-job-unavailable` state. The panel's
  DOM id contract (this ticket's plan) names exactly two ids: the panel
  itself and this one failure state; finer-grained splitting would
  duplicate `NucleusWeb.DataExportLive.States`' own per-kind work for a
  much smaller, supplementary panel.

  A retry affordance is included even though one of the two collapsed
  causes (the job genuinely not deployed yet) is not a transient failure a
  retry would fix — unlike `NucleusWeb.DataExportLive.States.not_enabled/1`,
  which omits retry for exactly that reason. Retrying a still-absent job is
  a harmless no-op (the check just re-runs and reaches the same
  conclusion), whereas omitting retry would hide the real recovery path for
  the other cause (a transient `Nucleus.NomadJobs.list/1` error) — for one
  DOM id, allowing retry costs nothing and never mishandles the other case.
  """

  use NucleusWeb, :html

  @doc """
  The Data Export job is either absent from `Nucleus.NomadJobs.list/1`'s
  result or that call itself errored — collapsed into one state, distinct
  from `NucleusWeb.DataExportLive.States.unavailable/1`'s
  `#data-export-unavailable` (that one is about the `:nomad_vars`
  boundary; this is about `:nomad_jobs`, and sharing an id would make a
  test asserting "the configuration table failed" pass or fail depending
  on this, unrelated, boundary).
  """
  attr :id, :string, default: "data-export-job-unavailable"

  def unavailable(assigns) do
    ~H"""
    <.empty_state
      id={@id}
      icon="hero-exclamation-triangle"
      message="Can't show the Data Export job's deployment status right now. Try again shortly."
    >
      <:action>
        <.button phx-click="retry_job_status">Retry</.button>
      </:action>
    </.empty_state>
    """
  end
end
