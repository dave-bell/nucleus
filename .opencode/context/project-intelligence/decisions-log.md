<!-- Context: project-intelligence/decisions | Priority: high | Version: 1.8 | Updated: 2026-08-14 -->

# Decisions Log

> Record major architectural and business decisions. Full context (rationale, alternatives,
> consequences) lives in the linked ADR — this file is the index and a scannable summary, not
> a duplicate of it.

## Quick Reference

- **Purpose**: Point future readers at the right ADR before they re-debate a settled question
- **Format**: One short entry per decision below the index; full analysis lives in `docs/adr/`
- **Status**: Decided | Pending | Under Review | Deprecated

## Decision Index

| # | Decision | Date | Status | ADR |
|---|----------|------|--------|-----|
| 1 | No local datastore — drop `ecto_sql`/`postgrex`, keep `ecto` for changesets | 2026-08-07 | Decided | `docs/adr/0001-no-local-datastore.md` |
| 2 | Backend adapter boundaries — behaviours, tagged-tuple errors, per-boundary real/local selection | 2026-08-07 | Decided | `docs/adr/0002-backend-adapter-boundaries.md` |
| 3 | Shared local backend seed — one supervised `Agent`, boundary-neutral, started everywhere | 2026-08-11 | Decided | `docs/adr/0003-shared-local-backend-seed.md` |
| 4 | Audit emission — bypasses `Logger`, synchronous `Sink` behaviour, per-event field allowlist | 2026-08-11 | Decided | `docs/adr/0004-audit-emission.md` |
| 5 | Deferred authentication — `Nucleus.Scope` seam, disabled-by-default provider, fail-loud `AUTH_ENABLED` | 2026-08-11 | Decided | `docs/adr/0005-deferred-authentication.md` |
| 6 | Application shell & live session composition — daisyUI retained, stacked `on_mount` hooks, placeholder `SecretsLive` ships now | 2026-08-11 | Decided | `docs/adr/0006-application-shell-and-live-session-composition.md` |
| 7 | Secrets store adapter — cluster/deployment Parameter Store path, `aws` package over `ex_aws`, `:persistent_term` credential cache, no dedicated local `Agent` | 2026-08-12 | Decided | `docs/adr/0007-secrets-store-adapter.md` |
| 8 | Test strategy — `Phoenix.LiveViewTest` + `PhoenixTest`, no browser driver; `Nucleus.BackendCase`/`AuditCase`/`LiveCase`; `mix nucleus.trace` report-only | 2026-08-14 | Decided | `docs/adr/0008-test-strategy.md` |
| 9 | Environment validation ladder — allowlist over denylist, strict validate-then-fetch ordering, no cache/no fallback ever, validation errors tagged `boundary: :tenant_api` | 2026-08-14 | Decided | `docs/adr/0009-environment-validation-ladder.md` |

This file deliberately contains **no "re-platform" decision** (fresh start, not a migration —
nothing to supersede) and **no inherited ADRs** (the wiki's `ADR-0001`–`ADR-0007` under
`docs/requirements/` are reference material only; adopting one is a decision made on its own
merits in `docs/adr/`, not by citation).

**Next decision likely needed** (tracked in `living-notes.md`): how a real token gets held and
refreshed across a long-lived LiveView socket — narrowed by EN-6 to a fixed `token` field on
`Nucleus.Scope`, still open on *how* it is held.

## Decision Template

`## Decision: [Title]` · `**Date**: YYYY-MM-DD | **Status**: ... | **ADR**: docs/adr/NNNN-slug.md`
· 2-4 sentences (what + the one-line reason; link the ADR for rationale/alternatives/consequences,
don't restate them) · `**Related**: [issue links, related decisions]`

---

## Decision: No Local Datastore

**Date**: 2026-08-07 | **Status**: Decided | **ADR**: `docs/adr/0001-no-local-datastore.md`

Dropped `ecto_sql`/`postgrex`/`Nucleus.Repo` and all database configuration and test-sandbox
plumbing; kept `ecto` + `phoenix_ecto` for `Ecto.Changeset`-driven forms. Nothing in scope needed
persistence, and the stateless constraint is now structurally enforced rather than documented —
adding a datastore back means adding a dependency and config, a visible, reviewable act.

**Related**: Issue #1 (EN-1) · Issue #14 (SEC-S6, the changeset consumer) · Issue #5 (EN-5, where
audit records actually go)

---

## Decision: Backend Adapter Boundaries

**Date**: 2026-08-07 | **Status**: Decided | **ADR**: `docs/adr/0002-backend-adapter-boundaries.md`

Every external system sits behind an Elixir **behaviour** with `real`/`local` implementations,
selected **per boundary**, never raising — callbacks return `{:error, %Nucleus.Backend.Error{}}`
with one of six neutral `kind`s. Every behaviour declares `health_check/0`. Auth is never
swappable. Local implementations ship with a loud boot warning; fault injection
(`LOCAL_LATENCY_MS`, `LOCAL_FORCE_ERROR`) is required, not optional.

**Related**: Issue #2 (EN-2) · Issues #3 (EN-3), #4 (EN-4) — the concrete boundaries · Issue #6
(EN-6, auth, deliberately outside the boundary set) · Issue #8 (EN-8, the contract test harness)

---

## Decision: Shared Local Backend Seed

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0003-shared-local-backend-seed.md`

One supervised `Agent`, `Nucleus.Backend.Seed` — boundary-neutral, started unconditionally in
every environment — parses `priv/backends/local_seed.json` once and holds it as state, keyed by
boundary section (`read/2`, `write/3`, `update/3`, test-only `reset/1`). Superseded the original
`GenServer`+ETS plan during EN-3's review: an `Agent` needs no table for a decoded JSON map, and
one shared owner lets `:tenant_api` (EN-3) and `:secrets` (EN-4) land in either order without
either redefining the file's shape for the other.

**Related**: Issue #3 (EN-3, the deciding issue) · Issue #4 (EN-4, next reader of the same seed
file) · `docs/adr/0002-backend-adapter-boundaries.md` (the real/local split this builds on)

---

## Decision: Audit Emission

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0004-audit-emission.md`

`Nucleus.Audit.emit/2` bypasses `Logger` entirely and writes through a `Nucleus.Audit.Sink`
behaviour, synchronously, in the caller's process, never rescuing a sink failure — `Logger` is
only synchronous under overload, and a rescued failure would look identical to a successful
record. Every field a caller can pass is allowlisted per event (`details` included), so there is
no key named `value` for a call site to pass a secret through by accident. The default sink
writes to `:stderr`, distinct from `Logger`'s standard-output default, for free.

**Related**: Issue #5 (EN-5, the deciding issue) · Issue #8 (EN-8, `AuditCase` depends on
`Nucleus.Audit.Sink.Test`) · Issues #12/#13/#14 (SEC-S4/S5/S6, wire the three Secrets events) ·
`docs/adr/0001-no-local-datastore.md` (audit records go to an external log pipeline; there is no
local option)

---

## Decision: Deferred Authentication

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0005-deferred-authentication.md`

`Nucleus.Scope` (`user`, `tenant`, `token`, `scopes`, `source_ip`) is the one shape every
LiveView, plug, and future audit call site reads identity from, whether auth is real or not.
`Nucleus.Scope.Provider.Disabled` (default, `AUTH_ENABLED=false`) never fails and returns a
single configured dev identity; `Nucleus.Scope.Provider.Cognito` is a stub that raises
unconditionally. Boot calls whichever is configured, so a bad `AUTH_ENABLED` fails loudly at
boot, not on first request. `token` is always `nil` for now — the field exists so retrofitting
real token passthrough later is a substitution, not a refactor of every call site that reads it.

**Related**: Issue #6 (EN-6, the deciding issue) · Issue #7 (EN-7, wires the plug/hook into the
router) · Issue #15 (SEC-S7, future consumer of the credential-expiry state `token` exists for) ·
`docs/adr/0004-audit-emission.md` (`Nucleus.Audit.Source.from_conn/1`, reused for `source_ip`)

---

## Decision: Application Shell & Live Session Composition

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0006-application-shell-and-live-session-composition.md`

Reversed the ticket's own daisyUI-removal recommendation — daisyUI stays; new components build
on its classes/tokens. `live_session :authenticated` stacks `on_mount: [ScopeHook,
EnvironmentsHook]`, the second reading `current_scope.token` the first assigns. `SecretsLive`
ships now as a documented placeholder because `~p` verified routes need a real compile-time
destination. The sidebar degrades to an empty state on load failure (`NAV-A07`); Secrets itself
stays fail-closed (`SEC-A17`) — deliberately asymmetric, not an oversight.

**Related**: Issue #7 (EN-7, the deciding issue) · `docs/adr/0005-deferred-authentication.md`
(the `on_mount`-at-`live_session` convention this builds on) · Issues #9/#10 (SEC-S1/S2, replace
the `SecretsLive` placeholder wholesale)

---

## Decision: Secrets Store Adapter

**Date**: 2026-08-12 | **Status**: Decided | **ADR**: `docs/adr/0007-secrets-store-adapter.md`

Parameter Store path is `/{cluster}/deployments/{deployment}/faas/functions/{environment}/{key}`,
decoupled from `Nucleus.TenantApi`'s environment list by design. AWS access goes through the
`aws` hex package (STS `AssumeRole`/`GetCallerIdentity`, SSM get/put/get-by-path) over a custom
`Req`-backed `AWS.HTTPClient`, chosen over `ex_aws` for SDK-accurate generated request shapes.
Credentials cache in `:persistent_term`; local state reads/mutates directly through EN-3's
`Nucleus.Backend.Seed`, reversing the ticket's original dedicated-`Agent` plan.

**Related**: Issue #4 (EN-4, the deciding issue) · `docs/adr/0003-shared-local-backend-seed.md`
(`Nucleus.Backend.Seed`, read and mutated here) · Issues #9–#15 (every SEC ticket touching
secret material, now unblocked)

---

## Decision: Test Strategy

**Date**: 2026-08-14 | **Status**: Decided | **ADR**: `docs/adr/0008-test-strategy.md`

`Phoenix.LiveViewTest` plus the new `phoenix_test` dependency replace the wiki's
Playwright-driven e2e layer — no browser driver added yet. `Nucleus.BackendCase` is
`async: false`, not the plan's hoped-for `async: true`-safe shape, because `Nucleus.Backend.Seed`
is a global `Agent` (`docs/adr/0003`), not a per-test process. `Nucleus.AuditCase` (async-safe)
and `NucleusWeb.LiveCase` (composing both plus `ConnCase`) round out the harness.
`mix nucleus.trace` diffs requirement action IDs against `@tag action:` claims, report-only —
not wired into `precommit` while most SEC tickets remain unimplemented. `SEC-A02`/`SEC-A13` are
recorded as browser-only gaps, asserted only for wiring, never claimed as covered.

**Related**: Issue #8 (EN-8, the deciding issue) · Issue #24 (timing-convention reconciliation
filed during this ticket) · Issues #9–#15 (every SEC ticket, the harness's first consumers)

---

## Decision: Environment Validation Ladder

**Date**: 2026-08-14 | **Status**: Decided | **ADR**: `docs/adr/0009-environment-validation-ladder.md`

`Nucleus.Environments.validate_name/1` rejects any environment name failing a positive charset
allowlist (`~r/\A[a-z0-9][a-z0-9-]*\z/`, ≤64 chars) — not a `..`/`/`/`\` denylist, which percent-
encoding and unicode lookalikes defeat. `fetch/2` runs it first, calls `TenantApi.list_environments/1`
only if it passes, collapses `:unavailable`/`:not_configured` to `:unavailable`, passes
`:auth_expired` through untouched, and matches archived environments too — with no cache and no
fallback list, ever. `NucleusWeb.SecretsLive` replaced its EN-7 placeholder wholesale, validating
in `handle_params/3` (not `mount/3`) so a patch between environments re-validates.

**Related**: Issue #9 (SEC-S1, the deciding issue) · `docs/adr/0006-application-shell-and-live-session-composition.md`
(the placeholder this ticket replaced) · `docs/adr/0007-secrets-store-adapter.md` (the boundary
that explicitly deferred this validation here) · Issues #10–#15 (SEC-S2–S7, every one mounts
through this gate)

---

## Deprecated Decisions

Decisions that were later overturned (for historical context):

| Decision | Date | Replaced By | Why |
|----------|------|-------------|-----|
| *(none — no decision has been overturned yet)* | — | — | — |

## Onboarding Checklist

- [ ] Read the Decision Index above; `adr/0001`–`0009` are binding
- [ ] Know that the wiki's ADR-0001–0007 are reference only, not adopted
- [ ] Know that new formal ADRs belong in `docs/adr/`, with only a short summary mirrored here
- [ ] Know which decisions are pending (see `living-notes.md`)

## Related Files

- `technical-domain.md` - Technical implementation affected by these decisions
- `business-tech-bridge.md` - How decisions connect business and technical
- `living-notes.md` - Current open questions that may become decisions
- `docs/adr/` - Formal ADR documents for this project, with full context/rationale/alternatives
