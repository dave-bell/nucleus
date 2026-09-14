# ADR-0031: Deployment Status Panel — Job-Absence Folds into `:not_found`, and the Read Loads via `assign_async/3`

## Status

Accepted — 2026-09-14

Decided on [DEX-S5](https://github.com/dave-bell/nucleus/issues/77). Consumes
`docs/adr/0026-applications-row-formatters-and-status-colour-test-gap.md`'s
`NucleusWeb.Nomad.JobFormat` directly — no independent status/version/
image/cron formatting here, per that ticket's own unblocking intent. Builds
on `docs/adr/0028-data-export-listing-single-module-dom-ids-and-fetch-list-split.md`
(the page, its `#data-export-unavailable` state, and the `fetch/1`/`list/1`
split this ticket's own panel must not collide with) and reuses
`lib/nucleus_web/live/environments_hook.ex`'s `Phoenix.LiveView.assign_async/3`
pattern, applied here for the first time to a LiveView's own primary content
rather than shell chrome.

## Context

`DEX-A02`'s plan asked for `fetch_data_export_job/1` to represent "the job
is absent from `Nucleus.NomadJobs.list/1`'s result" as either a bespoke
`{:not_found}` marker or folded into the existing `Nucleus.Backend.Error.kind()`
vocabulary, explicitly leaving the choice to implementation with instructions
to record it. It specified two DOM ids (`#data-export-job-status`,
`#data-export-job-unavailable`) and that the panel must render independently
of the configuration table's own `:status`/`:variables` assigns, but said
nothing about *how* the second read should be scheduled relative to
`mount/3`'s existing `NomadVars.fetch/1`/`list/1` call — an omission that
only surfaced once the panel was actually exercised against
`Nucleus.NomadJobs.list/1`'s own ~15s budget (`docs/adr/0022`, Decision 8).

## Decision

### Job absence folds into the existing `:not_found` kind, not a bespoke tuple

`fetch_data_export_job/1` returns `{:error, Error.new(:not_found, ...)}` when
the job is missing from the list, the same shape `Nucleus.NomadJobs.list/1`
itself returns for a transport-level failure. Chosen over the plan's own
`{:not_found}` alternative for consistency with every other boundary in this
codebase, which already uses `:not_found` for "the thing isn't there" —
`Nucleus.NomadVars.Store`'s own `:not_found` for "Data Export not enabled"
(`docs/adr/0028`) being the nearest sibling on the very same page. A bespoke
tuple would have forced `NucleusWeb.DataExportLive.JobStates` to pattern-match
a shape nothing else in the codebase produces, for no behavioural gain — the
panel collapses both causes into one rendered state regardless (next
decision), so a distinguishing tuple shape would have been dead weight.

### Both failure causes collapse into one DOM id, `#data-export-job-unavailable`

The job missing from the list (a real deployment scenario — Data Export
enabled via its Variables but the job not yet deployed, or vice versa) and
`Nucleus.NomadJobs.list/1` itself erroring are semantically distinct, but the
ticket's own DOM-id contract names exactly two ids for this panel: the panel
and one failure state. `NucleusWeb.DataExportLive.JobStates.unavailable/1` is
the single state both render into, with a retry affordance included even
though retrying a genuinely-undeployed job is a no-op — cheaper than a second
DOM id for a page section this small, and consistent with
`NucleusWeb.DataExportLive.States` collapsing every other
`Nucleus.Backend.Error.kinds/0` value the configuration table doesn't give
its own id (`docs/adr/0028`).

### The read loads via `Phoenix.LiveView.assign_async/3`, not a second synchronous `mount/3` call

The first implementation added `fetch_job_status/1` as a plain function
assigning `:job_status`/`:job` synchronously, chained after
`NomadVars.fetch/1`/`list/1` inside `mount/3` — mirroring
`NucleusWeb.ApplicationsLive`'s own unconditional, synchronous `fetch_jobs/1`
call. Caught in review: `Nucleus.NomadJobs.list/1` carries its own ~15s
overall budget (`docs/adr/0022`, Decision 8) precisely because a Nomad
namespace with many jobs can be slow, and chaining that budget after the
`NomadVars` call inside `mount/3` blocks *both* the disconnected and the
connected render — including the Configuration table below, which the
moduledoc's own independence claim says must render successfully regardless
of this boundary's health. `Nucleus.NomadJobs`'s own moduledoc already states
its intended call site is "a `Task`, not the LiveView process" (Decision 8);
a plain synchronous call in `mount/3` does not honour that.

Fixed by loading `:job` (a single `Phoenix.LiveView.AsyncResult`, replacing
the two-assign `:job_status`/`:job` pair) via `assign_async/3` — the same
mechanism `NucleusWeb.EnvironmentsHook` already uses for the sidebar's
Environments section, applied here for the first time to a LiveView's own
primary content. `assign_async/3` only spawns the fetch once
`connected?(socket)`, so the disconnected static render shows the `:loading`
slot instead of blocking on this boundary's own latency, and the template
renders the panel via `<.async_result assign={@job}>`'s `:loading`/`:failed`/
default slots rather than the previous `:if={@job_status == :ok}`/
`:if={@job_status == :unavailable}` pair. `"retry_job_status"` simply calls
`assign_async/3` again on the same key — Phoenix resets it to `:loading` and
re-runs; safe here since the button that triggers it only exists inside the
`:failed` slot, so there is never a running previous task to cancel first.

## Consequences

### Positive

- A slow or unavailable `Nucleus.NomadJobs` boundary can no longer delay
  first paint of the Configuration table, or of the page's own static HTML —
  the independence the moduledoc already claimed between the two boundaries
  now holds for *load time*, not only for *failure state*.
- `NucleusWeb.DataExportLive.JobStates` stays a two-DOM-id module exactly as
  planned, with no bespoke error shape to special-case anywhere else in the
  codebase.
- `:job`, a single `AsyncResult`, replaces a two-assign pair
  (`:job_status`/`:job`) that could in principle have drifted out of sync
  with each other; `Phoenix.Component.async_result/1` enforces the
  ok/loading/failed states are mutually exclusive by construction.

### Negative

- The deployment status panel now has a third render state
  (`#data-export-job-loading`) the Configuration table does not — that table
  still uses the synchronous `fetch/1`/`list/1` split (`docs/adr/0028`), so
  the two sibling sections of this same page are loaded by two different
  mechanisms for two different reasons. A future reader comparing them side
  by side needs this ADR, not just `docs/adr/0028`, to see why they diverge.
- `NucleusWeb.ApplicationsLive`'s own `mount/3` still calls `NomadJobs.list/1`
  synchronously, unchanged by this ticket — `Nucleus.NomadJobs`'s moduledoc
  claim that "`APP-S1` mounts immediately with a loading state and runs this
  call off the LiveView process" does not hold for that view today. Fixing
  it is out of scope for `DEX-S5` (a different ticket's LiveView); recorded
  in `living-notes.md` so it is not silently rediscovered as a fresh bug.
- Every `DEX-A02` test now calls `Phoenix.LiveViewTest.render_async/1` after
  mounting (and after `"retry_job_status"`'s `render_click/1`) to
  deterministically wait for the async task, matching `shell_test.exs`'s own
  convention for `EnvironmentsHook`'s async assign — a small but easy-to-omit
  addition; omitting it does not reliably fail the test locally (the `Local`
  backend resolves fast enough that a race usually resolves in the assertion's
  favour), so a missing `render_async/1` call here is a latent flake, not a
  guaranteed failure, and should not be treated as evidence the assign is
  synchronous.

## Alternatives considered

**A bespoke `{:not_found}` marker**, as the ticket's plan proposed as one
option. Rejected for the consistency reason above — every other "isn't
there" case on this same page already speaks `Error.kind() :not_found`.

**Two distinct DOM ids**, one for "job absent" and one for "list call
failed". Rejected — the ticket's own DOM-id contract names exactly two ids
for this panel total, and a retry affordance handles the "job genuinely
absent" case harmlessly (next section) rather than needing a
non-retryable-looking second state.

**Leaving the synchronous `mount/3` call as first shipped**, matching
`NucleusWeb.ApplicationsLive`'s existing pattern exactly. Rejected on
review — that pattern is itself a known, documented gap against
`Nucleus.NomadJobs`'s own moduledoc (see Negative, above), and repeating it
here would have blocked this page's Configuration table on a boundary that
has nothing to do with it, for a page that had just been given an explicit
independence guarantee between the two sections.

## References

- DEX-S5 (issue #77) — the deciding issue
- `docs/adr/0022-nomad-jobs-adapter.md` — the ~15s budget this ADR routes
  around via `assign_async/3` instead of a synchronous `mount/3` call
- `docs/adr/0025-applications-listing-single-module-and-name-derived-dom-ids.md`,
  `docs/adr/0026-applications-row-formatters-and-status-colour-test-gap.md` —
  `NucleusWeb.Nomad.JobFormat`, this ticket's shared, unmodified consumer
- `docs/adr/0028-data-export-listing-single-module-dom-ids-and-fetch-list-split.md`
  — the page, and the synchronous `fetch/1`/`list/1` split the Configuration
  table still uses, unchanged by this ADR
- `lib/nucleus_web/live/environments_hook.ex` — the `assign_async/3`
  precedent this ticket reuses for a LiveView's own content, not shell chrome
- `lib/nucleus_web/live/data_export_live/job_states.ex` — the single
  collapsed failure state's own moduledoc, with the same reasoning inline
- `living-notes.md` — `NucleusWeb.ApplicationsLive`'s own synchronous
  `NomadJobs.list/1` call recorded as a known, unfixed gap against this same
  boundary's moduledoc
