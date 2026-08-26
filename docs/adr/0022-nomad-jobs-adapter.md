# ADR-0022: Nomad Jobs Adapter

## Status

Accepted — 2026-08-25

Decided on [EN-11](https://github.com/dave-bell/nucleus/issues/57). Builds on
`0002-backend-adapter-boundaries.md` (behaviour/real-local shape),
`0003-shared-local-backend-seed.md` (`Nucleus.Backend.Seed`), and the
list-then-detail fan-out precedent `0016-m2m-client-adapter.md` set for
EN-10/#33's Cognito boundary.

## Context

`:nomad_jobs` is the boundary the `Applications` view (`docs/requirements/Applications.md`)
sits on — the EN-3/EN-10 adapter pattern applied to Nomad's HTTP API. Unlike
those two boundaries, this ticket's issue thread resolved **eight decisions
before implementation began**, three of which diverged from the plan the
issue body originally proposed. This ADR is the implementation-time record
of all eight, plus two design choices implementation itself required that
the decision thread did not need to settle. Full rationale for each
Decision lives in its own issue comment, linked below; this ADR does not
restate it.

## Decision

### 1. `Job.Version` from the detail response, not `Meta.version`

Nomad's scheduler revision integer — read from `GET /v1/job/:id`, never
`?meta=true` on the list call. Diverges from the plan, which recommended
`Meta.version`. The prototype's own precedent (`nomad.py:139`, reading
`job.get("Version", 0)` from the **list** response, which has no `Version`
field) is a bug, not a design to inherit — it returned `0` for every job,
so no expectation is anchored to that reading. `Job.Version` answers "which
submission of this jobspec is live," a real operational signal
`Meta.version` cannot restate from CI's own image-tag value.
([Decision](https://github.com/dave-bell/nucleus/issues/57#issuecomment-5417134643))

### 2. The periodic run count is dropped entirely

`periodic_run_count` does not exist on `Job.t()`. `JobSummary.Children` is
never read. `job_gc_threshold` (default 4h) permanently deletes terminal
periodic children, so a point-in-time `Children` sum is not a lifetime
total with a caveat — it is a number that looks like one, isn't, and never
grows for an hourly job. This deletes a binding `Then` clause from
`APP-A04`, tracked separately as APP-D2, not folded into APP-D1 (#60).
([Decision](https://github.com/dave-bell/nucleus/issues/57#issuecomment-5417135175))

### 3. Image from the task where `Lifecycle == nil`, never `Tasks[0]`

Preferring `Leader == true` if several qualify, otherwise the first in
order. No driver gate, no `Kind` filter, no new `Nucleus.Backend.Error`
kind — a job with no qualifying task is `image: nil` with no error, the
same ordinary absence as a job with no image configured. `Tasks[0]` is
wrong on this platform: every job has at least a primary task plus an
injected Consul Connect sidecar (appended, so it never leads), and commonly
an authored prestart task (conventionally written first). The prototype's
`nomad.py:159-166` demonstrates the exact bug `Lifecycle == nil` avoids. The
per-tenant Connect ingress gateway (no `Lifecycle` on its one task, image a
`${meta.connect.gateway_image}` template variable) is correctly selected by
this rule and yields the requirement's existing "template-variable image
reference, shown as-is" row — that row was simply never attributed to this
subject before.
([Decision](https://github.com/dave-bell/nucleus/issues/57#issuecomment-5417135625))

### 4. `ParentID` filtering applies to every child, not periodic children only

Parameterized/dispatch children are excluded from the list the same way
periodic children are — one predicate, no job-type branching, and cheaper
than the alternative (reading `ParameterizedJob` to restrict the filter
would need it anyway to find the dispatches).
([Decision](https://github.com/dave-bell/nucleus/issues/57#issuecomment-5417136001))

### 5. Cron spec: `Periodic.Specs` if non-empty, else `Periodic.Spec`

Not in the plan, which read only `Periodic.Spec`. Nomad 1.6.2 deprecated
HCL `cron` in favour of `crons` (`Periodic.Specs`, a list); the two fields
are mutually exclusive by validation (`nomad/structs/structs.go:5917-5920`
rejects a job with both set or with neither), with no canonicalisation
migrating one to the other, so reading both is unambiguous. No multi-cron
display rule is needed — no multi-cron jobspec is in use.
([Decision](https://github.com/dave-bell/nucleus/issues/57#issuecomment-5417136382))

### 6. One `detail_error` field, not three per-field `*_error` fields

```elixir
defstruct [:name, :status, :version, :namespace, :image, :cron, :periodic?, :detail_error]
```

`version`, `image`, and `cron` all come from the *same* per-job detail call
(Decisions 1, 3, 5) — a consequence of Decision 1 that did not hold when the
plan was written, since `Meta.version` would have come from the list call
and survived a detail-fetch failure on its own. Three parallel `*_error`
fields would carry the identical kind from the identical failure. Non-nil
`detail_error` means all three are unknown; nil means they are
authoritative, including `image: nil` meaning a genuine absence.
([Decision](https://github.com/dave-bell/nucleus/issues/57#issuecomment-5417136747))

### 7. `:nomad_jobs` / `NOMAD_JOBS_BACKEND`, diverging from wiki `ADR-0007`

The wiki's `ADR-0007` (reference-only, `docs/adr/0002:9-15`) names a single
`NOMAD_BACKEND`. Kept separate deliberately: job reads (this boundary) and
Nomad *Variables* (a future `:nomad_vars` boundary for Data Export,
read+write) are different capabilities with different access levels.
Collapsing them into one switch would put a write callback on the same
boundary as `APP-A08`'s read-only guarantee — exactly the coupling
`docs/adr/0002-backend-adapter-boundaries.md` exists to prevent. The shared
`Nucleus.Nomad.Transport` is what the two boundaries actually have in
common, which is why it is built as its own module now.
([Decision](https://github.com/dave-bell/nucleus/issues/57#issuecomment-5417137215))

### 8. Async load, bounded at two levels

`APP-S1` (#58) loads asynchronously rather than in a synchronous `mount`.
`Nucleus.NomadJobs.list/1` enforces a ~15s overall budget across the
fan-out (`Task.async/1` plus `Task.yield/2` + `Task.shutdown/2`), returning
`{:error, %Error{kind: :unavailable}}` if exceeded; `Nucleus.Nomad.Transport`
bounds each individual request at 10s (`receive_timeout`). `max_concurrency:
10` is retained from EN-10/#33's precedent rather than raised to shorten the
pathological case — that would triple instantaneous load on Nomad to
optimise a path that only occurs when Nomad is already unhealthy.
`timeout: :infinity` stays on `Task.async_stream/3` itself: the per-request
timeout is what should terminate one stalled task, not the stream's own
timer.
([Decision](https://github.com/dave-bell/nucleus/issues/57#issuecomment-5417137671))

### Implementation-time addition: one shared translation, not two

Not raised on the issue thread. `Nucleus.NomadJobs.Job.from_api/3`,
`.degraded/3`, and `.child?/1` are the only functions that read Nomad's
JSON shapes, and both `Nucleus.NomadJobs.Http` (a real list stub plus a
real detail response) and `Nucleus.NomadJobs.Local` (one seeded record
carrying the same two shapes under `"stub"`/`"detail"` keys) call them —
mirroring the precedent `Nucleus.TenantApi.Environment.from_api_list/1`
already set between `Http` and `.Local` one boundary over. This is what
lets a seed fixture (the leading-prestart-task-plus-injected-sidecar
fixture, the ingress-gateway fixture) prove Decisions 3 and 5's extraction
logic directly, rather than merely asserting that `Local` returns whatever
its own fixture already says.

### Implementation-time addition: the ~15s budget is configurable, not a literal

`Nucleus.NomadJobs.list/1` reads its budget from `config :nucleus,
Nucleus.NomadJobs, budget_ms: ...`, defaulting to 15,000. A hard-coded
module attribute would force the stalled-fan-out test Decision 8 itself
calls for to actually block for 15 real seconds; the config seam lets that
test arm a 50ms budget against a deliberately-stalling fake implementation
instead.

### Implementation-time correction: the fan-out runs unlinked from its caller

Caught in review, not on the issue thread. The first pass wrapped
`impl().list_jobs/1` in a bare `Task.async/1`. `Task.async/1` **links** the
spawned process to its caller, so an unhandled exception anywhere in the
fan-out — not just a classified `Nucleus.Backend.Error`, which
`Nucleus.NomadJobs.Http`'s own per-row `rescue` already degrades, but a
crash in `fetch_list/1`'s own parsing or a pattern-match failure on an
unexpected list-stub shape — would propagate the linked exit to whatever
process called `list/1` and kill it too, before `Task.yield/2` ever ran.
The `{:exit, reason}` branch existed in the `case` but was unreachable: the
caller died with the task before it could be evaluated. `Nucleus.Application`
now starts a `Task.Supervisor` (`Nucleus.TaskSupervisor`), and `list/1` uses
`Task.Supervisor.async_nolink/2` against it — the pattern the `Task` docs
name specifically for "the caller won't fail" when the task does. A test
(`test/nucleus/nomad_jobs_test.exs`, "a crash inside the fan-out") spawns
the caller in its own monitored process and asserts it exits `:normal` with
a classified error in hand, rather than going down with the task; reverting
to `Task.async/1` reproduces the failure and makes that test fail.

## Consequences

### Positive

- Both bugs the prototype's `nomad.py` carried (`Version` read from the
  wrong response; image read from the wrong task) are now impossible to
  reintroduce silently — each has its own test asserting the *wrong*
  reading would fail it, not merely that the right one passes.
- `Nucleus.Nomad.Transport` needs no change to support a future
  `:nomad_vars` boundary — it takes no assumption specific to jobs beyond
  its own `boundary` option, which every caller already supplies.
- The shared `Job.from_api/3`/`.degraded/3` translation means `Local`'s
  fixtures are not a second, independently-maintained model of Nomad's
  response shape — a Decision-3/5 regression in `Http` would also break the
  matching `Local` fixture test, not just its own.
- `APP-A07`'s error state is reachable within a bounded time under every
  failure mode this boundary can produce: a failed list call, a stalled
  fan-out, and (one layer up, in `Nucleus.NomadJobs.list/1`) an exceeded
  overall budget.

### Negative

- **`APP-D1` (#60) and `APP-D2` are now required before `APP-S2` (#59) can
  land correctly** — Decisions 1–3 each correct or remove a matrix row in
  `Applications.md` that predates this ticket. Neither is in this ticket's
  scope; both are called out explicitly in the Decision comments and in
  `APP-S1`/`APP-S2`'s own tickets.
- **A dispatch parent with zero dispatches now carries no activity
  indicator at all** (Decision 2's run count removal, compounded by
  Decision 4 folding dispatch parents into the same no-schedule rendering
  periodic parents get). Accepted as a trade in Decision 2's own comment;
  revisit with a boolean "has run" if this gap needs closing later.
- **`detail_error` couples three fields' fate together.** A future Nomad
  API change that makes only one of `Version`/image/cron detail-only would
  need this struct revisited — accepted because that is the actual shape of
  today's single detail call, not a hedge against a hypothetical split.

## Alternatives considered

**`Meta.version` via `GET /v1/jobs?meta=true`.** Rejected — see Decision 1.
Also would have implied a Nomad ≥ 1.4.x floor the accepted design does not
need.

**A windowed "N runs in the last `job_gc_threshold`" presentation instead of
dropping the run count outright.** Rejected — see Decision 2. Nucleus
cannot discover the window: `job_gc_threshold` is only exposed via
`/v1/agent/self`, which needs `agent:read`, a capability `ADR-0006` (wiki)
does not grant.

**A docker-driver gate, or a `Kind`-based exclusion, for image selection.**
Both rejected — see Decision 3. Every task in a Nucleus-managed job is a
container, so the driver discriminates nothing; excluding non-empty `Kind`
would skip a genuine connect-native primary task.

**`Job.VersionTag`** (Nomad 1.9+ named job versions). Considered and
rejected in Decision 1's own comment — the only candidate for which "not
available" would be genuinely meaningful, but nothing in the platform tags
job versions today. Revisit only if release naming is requested.

**`GET /v1/jobs/statuses`**, to avoid the fan-out entirely. Rejected —
undocumented, absent from the API sidebar, requires `read-job` rather than
`list-jobs`, has an open pagination bug
([hashicorp/nomad#28178](https://github.com/hashicorp/nomad/issues/28178)),
and returns neither the image, `Meta`, nor the cron spec, so it would not
remove the fan-out even if adopted.

**One `:nomad` boundary instead of `:nomad_jobs` + a future `:nomad_vars`.**
Rejected — see Decision 7.

**Raising `max_concurrency` above 10 to shorten the pathological fan-out
case.** Rejected — see Decision 8. Optimises a path that only occurs when
Nomad is already unhealthy, at the cost of tripling instantaneous load on
it, and diverges from EN-10's precedent for no benefit in the normal case.

## References

- EN-11 — [issue #57](https://github.com/dave-bell/nucleus/issues/57), the
  deciding issue, including the full implementation plan and all eight
  resolved decisions
- `docs/adr/0002-backend-adapter-boundaries.md` — the behaviour/real-local
  shape and neutral error kinds this implementation fills in
- `docs/adr/0003-shared-local-backend-seed.md` — `Nucleus.Backend.Seed`,
  read (never written) by `Nucleus.NomadJobs.Local`
- `docs/adr/0016-m2m-client-adapter.md` — the list-then-detail fan-out
  precedent (`Task.async_stream/3`, degrade-not-fail per row) this
  implementation follows exactly
- `docs/requirements/ADR-0006-Nomad-API-Authentication.md` (wiki,
  reference-only) — the static ACL token this adapter's `X-Nomad-Token`
  header implements, and the `list-jobs`/`read-job` capability grant this
  ticket's two-call-per-job design assumes
- `docs/requirements/ADR-0004-Explicit-Image-Versioning.md` (wiki,
  reference-only) — background for why "version" and "container image" are
  two distinct `Job` fields
- `docs/requirements/Applications.md` — `APP-A01`–`A08`; this ticket claims
  no `@tag action:` against any of them (APP-S1/#58, APP-S2/#59 claim all
  eight)
- APP-S1 (#58), APP-S2 (#59), APP-D1 (#60), APP-D2 — blocked by this
  ticket; APP-D1/APP-D2 must amend `Applications.md` before APP-S2 can
  label its columns correctly
- Prototype
  [`plugins/nomad.py`](https://github.com/SemaphoreSolutions/labbit-nucleus/blob/c462b1c397172b465d2936a2a31ff6dea29516ac/backend/src/control_plane/plugins/nomad.py) —
  source of the two transcribed bugs Decisions 1 and 3 correct
