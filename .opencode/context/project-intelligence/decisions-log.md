<!-- Context: project-intelligence/decisions | Priority: high | Version: 1.11 | Updated: 2026-08-17 -->

# Decisions Log

> The index of settled architectural decisions. Full context — rationale, alternatives,
> consequences, cross-references — lives in the linked ADR. This file is a pointer, never a
> duplicate: one row per decision, no prose sections.

## Quick Reference

- **Purpose**: Point future readers at the right ADR before they re-debate a settled question
- **Format**: One index row per decision. `docs/adr/` carries everything else, including each
  ADR's own `## References` (deciding issue, sibling ADRs, downstream tickets)
- **Status**: Decided | Pending | Under Review | Deprecated
- **Size**: 200-line MVI ceiling, held structurally — a row costs ~1 line, so the ceiling is not
  reachable by normal growth. **Do not reintroduce per-decision prose sections**: they made this
  file a third copy of the ADR and breached the ceiling at ten decisions (see v1.11)

## Adding a Decision

Append a row below. Write the ADR first — if the summary won't fit one row, the ADR is doing its
job and the row should point rather than paraphrase.

## Decision Index

| # | Decision | Date | Status | ADR |
|---|----------|------|--------|-----|
| 1 | No local datastore — drop `ecto_sql`/`postgrex`, keep `ecto` for changesets; stateless constraint now structurally enforced | 2026-08-07 | Decided | `docs/adr/0001-no-local-datastore.md` |
| 2 | Backend adapter boundaries — behaviours, tagged-tuple errors over six neutral `kind`s, per-boundary real/local selection, never raising; fault injection required | 2026-08-07 | Decided | `docs/adr/0002-backend-adapter-boundaries.md` |
| 3 | Shared local backend seed — one supervised `Agent`, boundary-neutral, started everywhere; superseded EN-3's own `GenServer`+ETS plan | 2026-08-11 | Decided | `docs/adr/0003-shared-local-backend-seed.md` |
| 4 | Audit emission — bypasses `Logger`, synchronous `Sink` in the caller's process, failures never rescued, per-event field allowlist with no key named `value` | 2026-08-11 | Decided | `docs/adr/0004-audit-emission.md` |
| 5 | Deferred authentication — `Nucleus.Scope` seam, disabled-by-default provider, fail-loud `AUTH_ENABLED`; `token` stays `nil` until substituted | 2026-08-11 | Decided | `docs/adr/0005-deferred-authentication.md` |
| 6 | Application shell & live session composition — daisyUI retained (reversing the ticket's own removal call), stacked `on_mount` hooks, sidebar degrades while Secrets stays fail-closed | 2026-08-11 | Decided | `docs/adr/0006-application-shell-and-live-session-composition.md` |
| 7 | Secrets store adapter — cluster/deployment Parameter Store path, `aws` package over `ex_aws`, `:persistent_term` credential cache, no dedicated local `Agent` | 2026-08-12 | Decided | `docs/adr/0007-secrets-store-adapter.md` |
| 8 | Test strategy — `Phoenix.LiveViewTest` + `PhoenixTest`, no browser driver (`SEC-A02`/`SEC-A13` left as recorded browser-only gaps); `BackendCase`/`AuditCase`/`LiveCase`; `mix nucleus.trace` report-only | 2026-08-14 | Decided | `docs/adr/0008-test-strategy.md` |
| 9 | Environment validation ladder — allowlist over denylist, strict validate-then-fetch ordering, no cache/no fallback ever, validation errors tagged `boundary: :tenant_api` | 2026-08-14 | Decided | `docs/adr/0009-environment-validation-ladder.md` |
| 10 | Secrets listing — one context call replaces two, ARN-hashed DOM ids with `data-key` carrying the real key, errors matched on `{kind, boundary}` | 2026-08-17 | Decided | `docs/adr/0010-secrets-listing-gate-collapse-and-dom-ids.md` |

No **"re-platform" decision** (fresh start) and no **inherited ADRs** — the wiki's `ADR-0001`–
`ADR-0007` are reference only; adopting one is a decision made on its own merits.

**Next decision likely needed** (`living-notes.md`): how a real token is held/refreshed across a
live socket — narrowed by EN-6 to a fixed `Nucleus.Scope.token` field, open on *how*.

## Deprecated Decisions

*None — no decision has been overturned yet.* Record one here when it happens: the decision, the
date, what replaced it, and why. A superseded row keeps its number and moves here rather than
being edited in place, so the ADR it points at stays findable.

## Onboarding Checklist

- [ ] Read the Decision Index above; `adr/0001`–`0010` are binding
- [ ] New formal ADRs belong in `docs/adr/`, with only an index row mirrored here — the wiki's
      ADR-0001–0007 are reference only, not adopted
- [ ] Know which decisions are pending (see `living-notes.md`)

## Related Files

- `technical-domain.md` - Technical implementation affected by these decisions
- `business-tech-bridge.md` - How decisions connect business and technical
- `living-notes.md` - Current open questions that may become decisions
- `docs/adr/` - Formal ADR documents for this project, with full context/rationale/alternatives
