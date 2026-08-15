# ADR-0008: Test Strategy

## Status

Accepted — 2026-08-14

Decided on [EN-8](https://github.com/dave-bell/nucleus/issues/8). Builds on
`0002-backend-adapter-boundaries.md` (`Nucleus.Backend.Seed`/`Faults`),
`0003-shared-local-backend-seed.md` (the global `Agent` this case wraps),
`0004-audit-emission.md` (`Nucleus.Audit.Sink.Test`), `0005-deferred-authentication.md`
(`Nucleus.Scope.Provider.Disabled`, why no sign-in step is needed to mount a
LiveView), and `0007-secrets-store-adapter.md` (confirms
`Nucleus.Secrets.Store.Local` has no `Agent` of its own).

**Numbering note**: the issue text named this file `0005-test-strategy.md`.
`0005` was taken by `deferred-authentication.md` from EN-6 by the time this
ticket started — a sequencing collision in the ticket text, not a decision
to revisit.

## Context

Every SEC ticket's plan declares test layers and `@tag action:` claims
against scaffolding that did not exist yet. Without a shared harness, each
would invent its own fakes and audit assertions — exactly the drift
`docs/requirements/`'s prototype ADR-0007 (wiki, reference only) documents:
hand-written `Fake*` classes living only in `tests/integration/conftest.py`,
drifting from what a developer could actually run.

The wiki's e2e layer assumed Playwright driving a React SPA
(`tests/e2e/*.spec.ts`, page objects). That architecture is gone, and no
Node toolchain exists in this repo. The issue's plan also called for
`Nucleus.BackendCase` to be `async: true` safe, contingent on verifying that
the local backends it wraps are per-test processes rather than a global
singleton.

## Decision

### `Phoenix.LiveViewTest` + `PhoenixTest`, no browser driver

`Phoenix.LiveViewTest` (mount, `handle_event`, `handle_params`, patches,
redirects, flash) plus the newly-added `phoenix_test` (~> 0.12.1, test-only)
dependency for flow-level tests spanning static and live pages together
cover what Playwright covered for the prototype's SPA. `test/nucleus_web/live/secrets_flow_test.exs`
demonstrates `PhoenixTest.visit/2` following a sidebar link across the
environment-picker navigation (EN-7).

Two things genuinely cannot be tested this way and are recorded as gaps, not
silently claimed as covered:

| Gap | Action | Why |
|---|---|---|
| Clipboard write and its visual confirmation | `SEC-A02` | `navigator.clipboard` is a browser API; a hook's behaviour is not executed |
| Escape-key dismissal, focus trap, focus restoration | `SEC-A13` | Real key events and focus management need a browser |

For these, tests assert the *wiring* (hook attached, `phx-window-keydown`
bound, `on_cancel` set) and never carry `@tag action:` for that ID — the
test does not prove the requirement's `Then` clauses, and claiming it would
make `mix nucleus.trace` blind to the real gap. Wallaby was considered for a
future browser harness (see Alternatives) but deferred until sign-in exists,
since auth is the flow that most needs a real browser.

### `Nucleus.BackendCase` is `async: false`, not the plan's hoped-for shape

The plan's `async: true`-safe design was contingent on the local backends
being per-test processes. They are not: `Nucleus.Backend.Seed` is one
globally-named `Agent`, started in the supervision tree in every
environment (`docs/adr/0003-shared-local-backend-seed.md`), and
`Nucleus.Secrets.Store.Local` has no `Agent` of its own — it reads and
mutates through that same global seed (`docs/adr/0007-secrets-store-adapter.md`).
`LOCAL_FORCE_ERROR`/`LOCAL_LATENCY_MS` (`Nucleus.Backend.Faults`) are
node-global environment variables for the same reason.

A case built on global, mutable, node-wide state cannot be `async: true`
safe. Any test that seeds, mutates, or injects a fault through
`Nucleus.BackendCase` runs `async: false`, matching the precedent
`test/nucleus/tenant_api/local_test.exs` and
`test/nucleus/secrets/store/local_test.exs` already set. The case's own
`setup` resets `Nucleus.Backend.Seed` and clears faults unconditionally in
`on_exit`, so leakage between tests is structurally prevented — but only
serialised tests can rely on it.

### One case per boundary, composed for LiveView tests

- **`Nucleus.BackendCase`** — `seed_secret/3`, `seed_environment/1`,
  `force_error/2`, `clear_faults/0` wrapping `Nucleus.Backend.Seed` and
  `Nucleus.Backend.Faults`'s env vars.
- **`Nucleus.AuditCase`** — registers the test process with
  `Nucleus.Audit.Sink.Test`; `async: true` safe, since registration stores
  the receiving pid in the *calling* process's dictionary, not global state.
  Provides `assert_audit_event/2`, `assert_no_audit_event/1`,
  `audit_events/0`, and `refute_audit_contains/1` — the reusable `AUD-A02`
  guard SEC-S4/S5/S6 will each need for secret values, checked against each
  record's raw encoded form so it cannot miss a leak into a field the helper
  didn't enumerate.
- **`NucleusWeb.LiveCase`** — composes `ConnCase` + `BackendCase` +
  `AuditCase` + `Phoenix.LiveViewTest`. Relies on EN-6's
  `Scope.Provider.Disabled` (`config/test.exs`) for there to be no sign-in
  step before mounting a LiveView. Adds `live_secrets/2`, a macro (not a
  function, since `Phoenix.LiveViewTest.live/2` itself needs the caller's
  `@endpoint` in scope) for the one route that exists today.

### `mix nucleus.trace`, deliberately not wired into `precommit`

Parses `### PREFIX-A##` headers from `docs/requirements/*.md` (excluding
`Home.md`'s worked `SEC-A03` example) and `action: "PREFIX-A##"` tags from
`test/`, reporting three buckets: covered, uncovered, and **claimed but
undefined** — the last catching a typo'd or renumbered ID that a plain
count would miss. Supports `--feature PREFIX` and `--exitcode`. Not added to
`mix precommit`: gating on total coverage while more than a dozen SEC
tickets remain open would block every commit before any of them lands. See
`living-notes.md`.

### Context-file updates landed after merge — a convention issue #24 has since replaced

`test/README.md` documents the layer table, tag vocabulary, and traceability convention inline,
and noted at review time that this ADR was not yet live. That was correct under the convention
in force when this ticket landed: per `ticket-delivery.md`'s then-current "After Merge" section —
matching how EN-1/EN-3/EN-5/EN-6/EN-7 actually shipped — this ADR, `living-notes.md`, and
`business-tech-bridge.md` were written in the landing commit, after the harness PR merged, not in
the PR itself. That history is not being rewritten here.

This ticket's own plan and acceptance-criteria checklist listed those same updates as PR-scope
deliverables, contradicting the guide it was implemented under — an inconsistency this ticket's
own kickoff surfaced and filed as issue #24. That issue's resolution changed the convention
**going forward**: `docs/adr/`, `decisions-log.md`, `business-tech-bridge.md`, and
`living-notes.md` updates now ship inside a ticket's own PR, as a dedicated commit written by the
`durable-record` skill and invoked by `/pr` — not as a follow-up `/land` commit. `/land` no longer
writes any of them. See `ticket-delivery.md`'s "Before Opening a PR" section and
`ticket-decisions.md`'s "Timing" table, both updated by issue #24.

## Consequences

### Positive

- Every SEC ticket inherits `refute_audit_contains/1` rather than
  reimplementing the AUD-A02 guard three separate ways.
- `NucleusWeb.LiveCase` needs zero per-test sign-in setup, so SEC tickets'
  LiveView tests start directly on the behaviour under test.
- `mix nucleus.trace --exitcode --feature SEC` gives a per-feature coverage
  gate any ticket can opt into locally, without forcing total-coverage
  gating on `precommit` before the feature set is complete.
- The `SEC-A02`/`SEC-A13` gaps are named once, here and in
  `living-notes.md`, instead of being silently rediscovered per ticket.

### Negative

- **`Nucleus.BackendCase` cannot run `async: true`.** Every LiveView test
  that seeds or mutates local backend state serialises with every other such
  test in the suite. This is a direct, accepted cost of `Nucleus.Backend.Seed`
  being global — revisiting it means revisiting `docs/adr/0003`, not this
  ADR.
- **No browser-driven coverage exists for `SEC-A02`/`SEC-A13`.** Wiring-only
  assertions are a lower bar than the requirement's `Then` clauses; a real
  regression in clipboard confirmation or focus-trap behavior would not be
  caught by this suite until Wallaby (or similar) lands.
- **`mix nucleus.trace` coverage is advisory, not enforced.** A ticket can
  merge with `mix precommit` green while under-reporting requirement
  coverage; nothing stops that today short of manually running the trace
  task.

## Alternatives considered

**Wallaby (ChromeDriver) now, for the two browser-only gaps.** Rejected for
this ticket. The issue's own recommendation was to defer a browser harness
until sign-in exists, since auth is the flow that most needs a real
browser, and no Node toolchain exists in this repo to add a competing
Playwright-based option instead.

**Keeping `Nucleus.BackendCase` `async: true` by giving `Nucleus.Backend.Seed`
a per-test-process mode.** Rejected. That would mean re-opening
`docs/adr/0003-shared-local-backend-seed.md`'s global-`Agent` decision for
the sake of test ergonomics alone; `async: false` on the tests that actually
mutate state is a smaller, more contained cost.

**Gating `mix precommit` on `mix nucleus.trace --exitcode`.** Rejected for
now. More than a dozen SEC tickets are still open with zero claimed
coverage; gating today would block every one of them from committing
anything until each requirement area is fully implemented. Revisit once
Secrets is complete, per `living-notes.md`.

## References

- EN-8 — the deciding issue, including the full implementation and test plan
- `docs/adr/0002-backend-adapter-boundaries.md` — `Nucleus.Backend.Seed`/
  `Faults`, wrapped by `Nucleus.BackendCase`
- `docs/adr/0003-shared-local-backend-seed.md` — the global `Agent` decision
  that makes `Nucleus.BackendCase` `async: false`
- `docs/adr/0004-audit-emission.md` — `Nucleus.Audit.Sink.Test`, wrapped by
  `Nucleus.AuditCase`
- `docs/adr/0005-deferred-authentication.md` — `Nucleus.Scope.Provider.Disabled`,
  why `NucleusWeb.LiveCase` needs no sign-in step
- `docs/adr/0007-secrets-store-adapter.md` — confirms `Nucleus.Secrets.Store.Local`
  has no `Agent` of its own
- `test/README.md` — the layer table, tag vocabulary, and traceability
  convention, in the form a developer reads day to day
- `.opencode/context/project-intelligence/business-tech-bridge.md` — the
  `action:` tagging convention this task enforces
- Issue #24 — filed during this ticket's own kickoff over the ticket-body-vs-workflow-guide
  timing inconsistency; resolved by moving doc updates into the ticket's own PR going forward
- `.opencode/skills/durable-record/SKILL.md` — the skill issue #24 introduced to write this
  record inside a ticket's PR, for tickets after this one
- Issues #9–#15 (every SEC ticket) — the harness's first consumers
