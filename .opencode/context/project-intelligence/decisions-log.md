<!-- Context: project-intelligence/decisions | Priority: high | Version: 1.9 | Updated: 2026-08-14 -->

# Decisions Log

> Record major architectural and business decisions. Full context (rationale, alternatives,
> consequences) lives in the linked ADR — this file is the index and a scannable summary, not
> a duplicate of it.

## Quick Reference

- **Purpose**: Point future readers at the right ADR before they re-debate a settled question
- **Format**: One short entry per decision below the index; full analysis lives in `docs/adr/`
- **Status**: Decided | Pending | Under Review | Deprecated
- **Size**: 200-line MVI ceiling. Hold each entry to ~3 lines plus `**Related**` — the ADR carries
  the rationale, alternatives, and consequences. Compact on the way in, not once it breaches

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

No **"re-platform" decision** exists (fresh start, not a migration) and no **inherited ADRs** —
the wiki's `ADR-0001`–`ADR-0007` under `docs/requirements/` are reference material only; adopting
one is a decision made on its own merits in `docs/adr/`, not by citation.

**Next decision likely needed** (tracked in `living-notes.md`): how a real token gets held and
refreshed across a long-lived LiveView socket — narrowed by EN-6 to a fixed `token` field on
`Nucleus.Scope`, still open on *how* it is held.

## Decision Template

`## Decision: [Title]` · `**Date**: YYYY-MM-DD | **Status**: ... | **ADR**: docs/adr/NNNN-slug.md`
· 2-3 sentences, ~3 lines · `**Related**: [issue links, related decisions]`

---

## Decision: No Local Datastore

**Date**: 2026-08-07 | **Status**: Decided | **ADR**: `docs/adr/0001-no-local-datastore.md`

Dropped `ecto_sql`/`postgrex`/`Nucleus.Repo` and all database and test-sandbox plumbing; kept
`ecto` + `phoenix_ecto` for changeset-driven forms. Nothing in scope needed persistence, and the
stateless constraint is now structurally enforced — adding a datastore back is a reviewable act.

**Related**: Issue #1 (EN-1) · Issue #14 (SEC-S6, the changeset consumer) · Issue #5 (EN-5, where
audit records actually go)

---

## Decision: Backend Adapter Boundaries

**Date**: 2026-08-07 | **Status**: Decided | **ADR**: `docs/adr/0002-backend-adapter-boundaries.md`

Every external system sits behind a behaviour with `real`/`local` implementations selected **per
boundary**, never raising — callbacks return `{:error, %Nucleus.Backend.Error{}}` with one of six
neutral `kind`s, and each declares `health_check/0`. Auth is never swappable. Local implementations
warn loudly at boot; fault injection (`LOCAL_LATENCY_MS`, `LOCAL_FORCE_ERROR`) is required.

**Related**: Issue #2 (EN-2) · Issues #3 (EN-3), #4 (EN-4) — the concrete boundaries · Issue #6
(EN-6, auth, deliberately outside the boundary set) · Issue #8 (EN-8, the contract test harness)

---

## Decision: Shared Local Backend Seed

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0003-shared-local-backend-seed.md`

One supervised `Agent`, `Nucleus.Backend.Seed` — boundary-neutral, started everywhere — parses
`priv/backends/local_seed.json` once and holds it keyed by boundary section. Superseded EN-3's
original `GenServer`+ETS plan: an `Agent` needs no table for a decoded map, and one shared owner
lets `:tenant_api` and `:secrets` land in either order.

**Related**: Issue #3 (EN-3, the deciding issue) · Issue #4 (EN-4, next reader of the same seed
file) · `docs/adr/0002-backend-adapter-boundaries.md` (the real/local split this builds on)

---

## Decision: Audit Emission

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0004-audit-emission.md`

`Nucleus.Audit.emit/2` bypasses `Logger` and writes through a synchronous `Nucleus.Audit.Sink` in
the caller's process, never rescuing a sink failure — a rescued failure would look identical to a
successful record. Every caller-passable field is allowlisted per event, so no key named `value`
exists for a call site to leak a secret through.

**Related**: Issue #5 (EN-5, the deciding issue) · Issue #8 (EN-8, `AuditCase` depends on
`Nucleus.Audit.Sink.Test`) · Issues #12/#13/#14 (SEC-S4/S5/S6, wire the three Secrets events) ·
`docs/adr/0001-no-local-datastore.md` (audit records go to an external log pipeline)

---

## Decision: Deferred Authentication

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0005-deferred-authentication.md`

`Nucleus.Scope` (`user`, `tenant`, `token`, `scopes`, `source_ip`) is the one shape every reader of
identity takes it from. `Provider.Disabled` (default) returns a dev identity and never fails,
`Provider.Cognito` raises, and boot calls whichever is configured so a bad `AUTH_ENABLED` fails at
boot. `token` is always `nil` — it exists so real passthrough is a substitution, not a refactor.

**Related**: Issue #6 (EN-6, the deciding issue) · Issue #7 (EN-7, wires the plug/hook into the
router) · Issue #15 (SEC-S7, future consumer of the credential-expiry state `token` exists for) ·
`docs/adr/0004-audit-emission.md` (`Nucleus.Audit.Source.from_conn/1`, reused for `source_ip`)

---

## Decision: Application Shell & Live Session Composition

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0006-application-shell-and-live-session-composition.md`

Reversed the ticket's own daisyUI-removal recommendation — daisyUI stays; new components build on
its classes/tokens. `live_session :authenticated` stacks `on_mount: [ScopeHook, EnvironmentsHook]`,
the second reading the `current_scope.token` the first assigns. The sidebar degrades to an empty
state on load failure (`NAV-A07`) while Secrets stays fail-closed (`SEC-A17`) — asymmetric by
design, not by oversight.

**Related**: Issue #7 (EN-7, the deciding issue) · `docs/adr/0005-deferred-authentication.md`
(the `on_mount`-at-`live_session` convention this builds on) · Issues #9/#10 (SEC-S1/S2, replaced
the `SecretsLive` placeholder wholesale)

---

## Decision: Secrets Store Adapter

**Date**: 2026-08-12 | **Status**: Decided | **ADR**: `docs/adr/0007-secrets-store-adapter.md`

Parameter Store path is `/{cluster}/deployments/{deployment}/faas/functions/{environment}/{key}`,
decoupled from `Nucleus.TenantApi`'s environment list by design. AWS access goes through the `aws`
hex package over a custom `Req`-backed `AWS.HTTPClient`, chosen over `ex_aws` for SDK-accurate
request shapes, with credentials cached in `:persistent_term`. Local state reads and mutates EN-3's
`Nucleus.Backend.Seed` directly, reversing the ticket's dedicated-`Agent` plan.

**Related**: Issue #4 (EN-4, the deciding issue) · `docs/adr/0003-shared-local-backend-seed.md`
(`Nucleus.Backend.Seed`, read and mutated here) · Issues #9–#15 (every SEC ticket touching
secret material, now unblocked)

---

## Decision: Test Strategy

**Date**: 2026-08-14 | **Status**: Decided | **ADR**: `docs/adr/0008-test-strategy.md`

`Phoenix.LiveViewTest` plus the new `phoenix_test` dependency replace the wiki's Playwright-driven
e2e layer — no browser driver yet, so `SEC-A02`/`SEC-A13` are recorded as browser-only gaps,
asserted for wiring and never claimed as covered. `Nucleus.BackendCase` is `async: false` because
`Nucleus.Backend.Seed` is a global `Agent` (`docs/adr/0003`); `AuditCase` and `NucleusWeb.LiveCase`
are async-safe. `mix nucleus.trace` is report-only, not wired into `precommit`.

**Related**: Issue #8 (EN-8, the deciding issue) · Issue #24 (timing-convention reconciliation
filed during this ticket) · Issues #9–#15 (every SEC ticket, the harness's first consumers)

---

## Decision: Environment Validation Ladder

**Date**: 2026-08-14 | **Status**: Decided | **ADR**: `docs/adr/0009-environment-validation-ladder.md`

`Nucleus.Environments.validate_name/1` rejects any name failing a positive charset allowlist
(`~r/\A[a-z0-9][a-z0-9-]*\z/`, ≤64 chars) — not a `..`/`/`/`\` denylist, which percent-encoding and
unicode lookalikes defeat. `fetch/2` runs it first, collapses `:unavailable`/`:not_configured` to
`:unavailable`, passes `:auth_expired` through untouched, and matches archived environments too,
with no cache and no fallback ever. `SecretsLive` validates in `handle_params/3`, not `mount/3`, so
a patch between environments re-validates.

**Related**: Issue #9 (SEC-S1, the deciding issue) · `docs/adr/0006-application-shell-and-live-session-composition.md`
(the placeholder this ticket replaced) · `docs/adr/0007-secrets-store-adapter.md` (the boundary
that explicitly deferred this validation here) · Issues #10–#15 (SEC-S2–S7, every one mounts
through this gate)

---

## Deprecated Decisions

*None — no decision has been overturned yet.* Record one here when it happens: the decision, the
date, what replaced it, and why.

## Onboarding Checklist

- [ ] Read the Decision Index above; `adr/0001`–`0009` are binding
- [ ] Know that new formal ADRs belong in `docs/adr/`, with only a short summary mirrored here,
      and that the wiki's ADR-0001–0007 are reference only, not adopted
- [ ] Know which decisions are pending (see `living-notes.md`)

## Related Files

- `technical-domain.md` - Technical implementation affected by these decisions
- `business-tech-bridge.md` - How decisions connect business and technical
- `living-notes.md` - Current open questions that may become decisions
- `docs/adr/` - Formal ADR documents for this project, with full context/rationale/alternatives
