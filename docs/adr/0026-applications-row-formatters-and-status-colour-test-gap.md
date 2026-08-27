# ADR-0026: Applications Row Formatters — Shared `JobFormat` Module, Column Text, and the Status-Colour Test Gap

## Status

Accepted — 2026-08-26

Decided on [APP-S2](https://github.com/dave-bell/nucleus/issues/59). Fills in
the three empty placeholder cells and the status text `0025-applications-listing-single-module-and-name-derived-dom-ids.md`
shipped, against the `Job.t()` fields `0022-nomad-jobs-adapter.md` fixed.
Builds on `0019-m2m-client-detail-mount-audit-guard-and-token-validity.md`'s
`Format.created_date/1` precedent (a shared formatter, not two independently
maintained private helpers) and adds to `0008-test-strategy.md`'s recorded
browser-gap convention.

## Context

The issue body drifted substantially between being written and being
started — `APP-D1` (#60) and `APP-D2` (#68) each amended
`docs/requirements/Applications.md` out from under it, and a review comment
on `APP-S1` (#58) caught two more stale references before this ticket
opened. None of that drift reached the code: `Job.t()` already has no
`image_error` (one `detail_error` covers version/image/cron together,
Decision 6) and no `periodic_run_count` (dropped outright, Decision 2), and
`docs/requirements/Applications.md`'s `APP-A04` already has no run-count
clause. This ADR is therefore implementation-time only — no plan
reconciliation was needed, only the four formatting decisions below and the
one test-observability gap `APP-A02` opens.

`APP-A02`–`APP-A05` are the same table's remaining cell contents, not four
independent behaviours (the issue's own framing), and `DEX-A02` (DEX-S5,
#77) is a second, already-known consumer of the same `Job` struct — blocked
on this ticket per its own issue body.

## Decision

### `NucleusWeb.Nomad.JobFormat` — one shared module, five functions

`lib/nucleus_web/nomad/job_format.ex`: `status_class/1`, `status_text/1`,
`version_text/1`, `image_text/1`, `schedule_text/1`, all `Job.t() ->
String.t()`. `status_text/1` was not in the issue's suggested shape but
`DEX-S5`'s own plan calls `JobFormat.status_text(job)` for its
`<.description_list>` row — added so that ticket has no reason to reach into
`Job.status` directly instead of the shared module, avoiding exactly the
drift `M2MClientsLive.Format` exists to prevent for `created_date/1`.

### `detail_error` degrades version, image, *and* schedule text identically

Every formatter checks `detail_error` first and returns the same `"not
available"` string. This includes `schedule_text/1` for a degraded
*periodic* job: `periodic?` is accurate on a degraded row (it comes from the
list stub, never the detail call), but the cron spec is one of the three
detail-sourced fields, so rendering it as unavailable — rather than as `"No
schedule"` or as the (unknown) cron text — is the only reading consistent
with `Job.t()`'s own invariant ("non-nil `detail_error` means `version`,
`image`, **and** `cron` are all unknown"). No seed fixture exercises this
path today (`Nucleus.NomadJobs.Local` never calls `Job.degraded/3` — only
`Http` does, on a real per-job detail failure), so this is proven at
`job_format_test.exs`'s pure-unit layer by constructing the struct directly,
not through the LiveView.

### `image: nil` and `detail_error` collapse to the same text, for different reasons

A job with no task where `Lifecycle == nil` (Decision 3, `0022`) has `image:
nil` with `detail_error: nil` — a genuine absence, not a failure.
`image_text/1` renders `"not available"` for both this case and the
degraded case, matching `APP-A03`'s edge-case matrix requirement that
neither state renders blank, but the two remain distinct conditions in the
struct; the shared text is a display choice, not a claim that they mean the
same thing.

### The status badge is a nested pill, vertically centered in its cell

`docs/adr/0025` fixed the status cell's id at the `<td>`. The first pass
kept that literally — `status_class/1`'s `"badge badge-{success,warning,error,neutral}"`
string applied as the `<td>`'s own `class`, so the id and class stayed on
one element and the diff touched no new nodes. Caught in review: a `<td>`
carrying `.badge` doesn't read as a pill — the badge fills the cell's full
height rather than sitting as a centered, inline-sized chip, which is what
`APP-A02`'s "visually distinguished... in addition to the status text"
actually calls for. The id and class move onto a `<span>` nested inside the
`<td>` (`<td class="align-middle"><span id="job-{name}-status" class="badge
badge-...">...</span></td>`), with `align-middle` on the `<td>` so the pill
centers vertically in the row regardless of the row's height. This is the
"nested `<span>`" alternative the first pass rejected as a markup-structure
change outside scope — accepted after all, since "content-only" was never
meant to block a one-ticket-old placeholder cell from gaining the child
node its own content needs to render correctly, and the DOM id contract
(`#job-{name}-status` exists, addressable, carries the class) is unchanged
regardless of which element holds it.

Existing and new tests are unaffected: `has_element?/2` matches by id
regardless of tag, so every `#job-{name}-status`-based assertion
(`APP-A01`'s existence check, `APP-A02`'s class checks) passes against the
`<span>` exactly as it did against the `<td>`.

### The Version column is retitled "Job revision"

Per `docs/adr/0022`'s own framing (`Job.Version` is Nomad's scheduler
revision counter, not a release identifier) and `APP-D1`'s amendment to
`APP-A03`. The DOM id stays `#job-{name}-version` — `docs/adr/0025`'s fixed
contract names the field, not the visible header text, and DEX-S5 (#77)
resolves the same job by struct field regardless of what any table header
says.

### `APP-A02`'s rendered colour is a recorded test gap, not silently claimed

Mirroring `docs/adr/0008-test-strategy.md`'s convention (clipboard writes,
Escape-dismissal): the CSS class per status is asserted directly
(`has_element?(view, "#job-...-status.badge-success")`), and all three
classes' pairwise distinctness is asserted in `job_format_test.exs`, but the
rendered pixel colour itself is not observable through
`Phoenix.LiveViewTest` and is not claimed as proven beyond the class
attribute. `test/README.md`'s gap table — the living aggregator later
tickets (`M2M-A10`, `SEC-A04`) have each added their own row to, rather than
editing the frozen `0008` acceptance record itself — gains a row for this
gap.

## Consequences

### Positive

- `DEX-S5` (#77) is unblocked with a concrete, tested module to call rather
  than a name promised by this ticket's plan.
- `job_format_test.exs` proves the `detail_error`-degraded and no-image
  cases directly against constructed structs, independent of whether a seed
  fixture for either exists — so the pure formatting logic is covered even
  though `Nucleus.NomadJobs.Local` has no degraded fixture today.
- `mix nucleus.trace --feature APP` reports all eight `APP-A*` actions
  covered.

### Negative

- No seed fixture exercises a `detail_error`-degraded row through the
  LiveView end-to-end; the condition is proven only at the formatter's pure
  unit-test layer. Revisit if `Nucleus.NomadJobs.Local` ever grows a
  degraded fixture (e.g. for a future ticket that needs one for its own
  reasons).

## Alternatives considered

**The badge class on the `<td>` itself, no nested `<span>`.** The first
pass, and the more literal reading of `APP-S2`'s "content-only" scope note.
Rejected on review — see the Decision above — because a `<td>` carrying
`.badge` doesn't render as a pill, it colors the whole cell, which reads as
a bigger visual change than the nested-span alternative it was chosen to
avoid.

**A fourth `*_error`-style clause per formatter, matching each field's own
nil-ness independently of `detail_error`.** Rejected — `Job.t()`'s own
invariant (Decision 6, `0022`) already couples version/image/cron's fate
together; re-deriving that per formatter would just restate the struct's
own guarantee three times, with three chances to drift from it.

**Editing `docs/adr/0008-test-strategy.md`'s gap table directly.** Rejected
— that file is the frozen acceptance record from EN-8; `M2M-A10` and
`SEC-A04`'s gaps were each recorded in their own ticket's ADR and folded
only into `test/README.md`'s living table, not back into `0008` itself.
This ADR follows that precedent rather than reopening `0008`.

## References

- APP-S2 (issue #59) — the deciding issue
- `docs/adr/0022-nomad-jobs-adapter.md` — `Job.t()`'s fields and the
  `detail_error` invariant this ticket's formatters read
- `docs/adr/0025-applications-listing-single-module-and-name-derived-dom-ids.md`
  — the fixed DOM-id contract and "content-only" scope this ticket honours
- `docs/adr/0019-m2m-client-detail-mount-audit-guard-and-token-validity.md`
  — the `Format.created_date/1` shared-formatter precedent
- `docs/adr/0008-test-strategy.md` — the recorded-browser-gap convention;
  `test/README.md` is where later gaps (`M2M-A10`, `SEC-A04`, and now
  `APP-A02`) actually accumulate
- DEX-S5 (issue #77) — the second consumer of `NucleusWeb.Nomad.JobFormat`,
  unblocked by this ticket
