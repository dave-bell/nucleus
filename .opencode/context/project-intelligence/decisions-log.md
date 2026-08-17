<!-- Context: project-intelligence/decisions | Priority: high | Version: 1.10 | Updated: 2026-08-17 -->

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
| 10 | Secrets listing — one context call replaces two, ARN-hashed DOM ids, errors matched on `{kind, boundary}` | 2026-08-17 | Decided | `docs/adr/0010-secrets-listing-gate-collapse-and-dom-ids.md` |

No **"re-platform" decision** (fresh start) and no **inherited ADRs** — the wiki's `ADR-0001`–
`ADR-0007` are reference only; adopting one is a decision made on its own merits.

**Next decision likely needed** (`living-notes.md`): how a real token is held/refreshed across a
live socket — narrowed by EN-6 to a fixed `Nucleus.Scope.token` field, open on *how*.

## Decision Template

`## Decision: [Title]` · `**Date**: YYYY-MM-DD | **Status**: ... | **ADR**: docs/adr/NNNN-slug.md`
· 2-3 sentences, ~3 lines · `**Related**: [issue links, related decisions]`

---

## Decision: No Local Datastore

**Date**: 2026-08-07 | **Status**: Decided | **ADR**: `docs/adr/0001-no-local-datastore.md`

Dropped `ecto_sql`/`postgrex`/`Nucleus.Repo` and all database and test-sandbox plumbing; kept
`ecto` + `phoenix_ecto` for changeset-driven forms. Nothing in scope needed persistence, and the
stateless constraint is now structurally enforced — adding a datastore back is a reviewable act.

**Related**: Issue #1 (EN-1) · Issue #14 (SEC-S6, changeset consumer) · Issue #5 (EN-5, audit destination)

---

## Decision: Backend Adapter Boundaries

**Date**: 2026-08-07 | **Status**: Decided | **ADR**: `docs/adr/0002-backend-adapter-boundaries.md`

Every external system sits behind a behaviour with `real`/`local` implementations selected **per
boundary**, never raising — errors return `{:error, %Nucleus.Backend.Error{}}` with one of six
neutral `kind`s. Local implementations warn loudly at boot; fault injection is required.

**Related**: Issue #2 (EN-2) · Issues #3/#4 (concrete boundaries) · Issue #6 (auth, outside scope)
· Issue #8 (contract harness)

---

## Decision: Shared Local Backend Seed

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0003-shared-local-backend-seed.md`

One supervised `Agent`, `Nucleus.Backend.Seed` — boundary-neutral, started everywhere — parses
`priv/backends/local_seed.json` once and holds it keyed by boundary section. Superseded EN-3's
original `GenServer`+ETS plan: an `Agent` needs no table for a decoded map, and one shared owner
lets `:tenant_api` and `:secrets` land in either order.

**Related**: Issue #3 (EN-3, deciding issue) · Issue #4 (EN-4, next reader) · `docs/adr/0002`
(the real/local split this builds on)

---

## Decision: Audit Emission

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0004-audit-emission.md`

`Nucleus.Audit.emit/2` bypasses `Logger` and writes through a synchronous `Nucleus.Audit.Sink` in
the caller's process, never rescuing a sink failure — a rescued failure would look identical to a
successful record. Every caller-passable field is allowlisted per event, so no key named `value`
exists for a call site to leak a secret through.

**Related**: Issue #5 (EN-5, deciding issue) · Issue #8 (`AuditCase`) · Issues #12–14 (SEC-S4–S6,
wire the 3 events) · `docs/adr/0001` (external log pipeline)

---

## Decision: Deferred Authentication

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0005-deferred-authentication.md`

`Nucleus.Scope` (`user`, `tenant`, `token`, `scopes`, `source_ip`) is the one identity shape every
reader takes it from. `Provider.Disabled` (default) never fails; `Provider.Cognito` raises, so a
bad `AUTH_ENABLED` fails at boot. `token` stays `nil` — populating it later is a substitution.

**Related**: Issue #6 (EN-6, deciding issue) · Issue #7 (wires the plug/hook) · Issue #15 (SEC-S7,
credential-expiry consumer) · `docs/adr/0004` (`source_ip` reuse)

---

## Decision: Application Shell & Live Session Composition

**Date**: 2026-08-11 | **Status**: Decided | **ADR**: `docs/adr/0006-application-shell-and-live-session-composition.md`

Reversed the ticket's own daisyUI-removal call — daisyUI stays; new components build on its
classes/tokens. `live_session :authenticated` stacks `on_mount: [ScopeHook, EnvironmentsHook]`. The
sidebar degrades on load failure (`NAV-A07`) while Secrets stays fail-closed (`SEC-A17`) —
asymmetric by design.

**Related**: Issue #7 (EN-7, deciding issue) · `docs/adr/0005` (on_mount convention this builds on)
· Issues #9/#10 (SEC-S1/S2, replaced the placeholder)

---

## Decision: Secrets Store Adapter

**Date**: 2026-08-12 | **Status**: Decided | **ADR**: `docs/adr/0007-secrets-store-adapter.md`

Parameter Store path is `/{cluster}/deployments/{deployment}/faas/functions/{environment}/{key}`,
decoupled from `Nucleus.TenantApi`'s environment list by design. AWS access goes through the `aws`
package (over `ex_aws`, for SDK-accurate shapes), credentials cached in `:persistent_term`; local
state reads/mutates EN-3's `Nucleus.Backend.Seed` directly.

**Related**: Issue #4 (EN-4, deciding issue) · `docs/adr/0003` (`Seed`, read/mutated here) ·
Issues #9–#15 (every SEC ticket touching secret material, now unblocked)

---

## Decision: Test Strategy

**Date**: 2026-08-14 | **Status**: Decided | **ADR**: `docs/adr/0008-test-strategy.md`

`Phoenix.LiveViewTest` + the new `phoenix_test` dep replace the wiki's Playwright e2e layer — no
browser driver yet, so `SEC-A02`/`SEC-A13` are recorded as browser-only gaps, never claimed
covered. `BackendCase` is `async: false` (global `Agent` seed); `AuditCase`/`LiveCase` are async-safe.

**Related**: Issue #8 (EN-8, deciding issue) · Issue #24 (timing reconciliation) · Issues #9–#15
(every SEC ticket, the harness's first consumers)

---

## Decision: Environment Validation Ladder

**Date**: 2026-08-14 | **Status**: Decided | **ADR**: `docs/adr/0009-environment-validation-ladder.md`

`Nucleus.Environments.validate_name/1` rejects any name failing a positive charset allowlist
(`~r/\A[a-z0-9][a-z0-9-]*\z/`, ≤64 chars), not a denylist, which percent-encoding/unicode defeat.
`fetch/2` validates first, collapses `:unavailable`/`:not_configured`, passes `:auth_expired`
through, and matches archived environments too, with no cache/fallback ever.

**Related**: Issue #9 (SEC-S1, deciding issue) · `docs/adr/0006` (placeholder replaced) ·
`docs/adr/0007` (the boundary that deferred validation here) · Issues #10–#15 (SEC-S2–S7, every
one mounts through this gate)

---

## Decision: Secrets Listing — Gate Collapse, ARN-Hashed DOM IDs, Boundary-Matched Errors

**Date**: 2026-08-17 | **Status**: Decided | **ADR**: `docs/adr/0010-secrets-listing-gate-collapse-and-dom-ids.md`

`Nucleus.Secrets.list/2` collapses `SecretsLive`'s two backend calls into one, gating through
`Environments.fetch/2` internally — the dead `resolved_environment` assign is gone. Row DOM ids
hash the ARN, not the key (no sanitiser existed); `data-key` carries the real key. Errors match on
`{kind, boundary}`, telling the gate's `:unavailable` apart from the store's — also fixing a
latent `:auth_expired` crash.

**Related**: Issue #10 (SEC-S2) · `docs/adr/0009` (gate called once) · `docs/adr/0007` (`:secrets`
boundary) · Issues #11–#15 (SEC-S3–S7 build on this DOM-id/error contract)

---

## Deprecated Decisions

*None — no decision has been overturned yet.* Record one here when it happens: the decision, the
date, what replaced it, and why.

## Onboarding Checklist

- [ ] Read the Decision Index above; `adr/0001`–`0010` are binding
- [ ] New formal ADRs belong in `docs/adr/`, with only a short summary mirrored here — the wiki's
      ADR-0001–0007 are reference only, not adopted
- [ ] Know which decisions are pending (see `living-notes.md`)

## Related Files

- `technical-domain.md` - Technical implementation affected by these decisions
- `business-tech-bridge.md` - How decisions connect business and technical
- `living-notes.md` - Current open questions that may become decisions
- `docs/adr/` - Formal ADR documents for this project, with full context/rationale/alternatives
