<!-- Context: project-intelligence/decisions | Priority: high | Version: 1.17 | Updated: 2026-08-19 -->

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
| 11 | Secret reveal — re-stream a converted `SecretRef` (never the value-bearing `Secret`), audit `user:` via `Scope.audit_user/1`, `Nucleus.Audit.Sink.Test` falls back to `$callers` for LiveView-emitted audit events | 2026-08-18 | Decided | `docs/adr/0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md` |
| 12 | Secret reveal moves into a conditionally-rendered modal (plaintext never in the DOM while closed), Value column deleted outright, copy buttons icon-only with the label as a daisyUI tooltip; partially supersedes #11's map/re-stream mechanics | 2026-08-18 | Decided | `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md` |
| 13 | Secret edit lives inside the reveal modal via content-swap-in-place (no second `<.modal>`), gated on `socket.assigns.revealed` matching `%Secret{key: ^key}`; `Nucleus.Secrets.Value` and an `embedded_schema` edit form set the pattern `SEC-S6` reuses | 2026-08-18 | Decided | `docs/adr/0013-secret-edit-in-modal-and-value-form.md` |
| 14 | Secret creation — one consolidated `Nucleus.Secrets.Key.validate/1` (denylist, no casing rule, `Error.t()` shape matching `Value`), `create/4` relies on the store's atomic `:already_exists` refusal, and the creation modal is mutually exclusive with the reveal modal to structurally avoid ADR-0012's `focusStack` double-pop | 2026-08-19 | Decided | `docs/adr/0014-secret-creation-key-consolidation-and-modal-exclusion.md` |
| 15 | Shared AWS identity seam — two independent role ARNs (`TENANT_ROLE_ARN`, EN-10's `COGNITO_ROLE_ARN`), credential cache keyed on `{role_arn, external_id, session_name}` not the caller, region parameterised now with the second variable and its wiki amendment deferred to EN-10 | 2026-08-19 | Decided | `docs/adr/0015-shared-aws-identity-seam.md` |
| 16 | M2M client adapter — derived OAuth scope (no new config var), operator-chosen token validity (5–60 min, stored in seconds), bounded fan-out with degrade-not-fail listing; `M2M-A09` removed mid-implementation — Cognito does not enforce client-name uniqueness | 2026-08-19 | Decided | `docs/adr/0016-m2m-client-adapter.md` |

No **"re-platform" decision** (fresh start) and no **inherited ADRs** — the wiki's `ADR-0001`–
`ADR-0007` are reference only; adopting one is a decision made on its own merits.

**Next decision likely needed** (`living-notes.md`): how a real token is held/refreshed across a
live socket — narrowed by EN-6 to a fixed `Nucleus.Scope.token` field, open on *how*.

## Deprecated Decisions

Row **11**'s reveal *mechanics* are partially superseded by row 12 (2026-08-18): `:revealed` is a
single `Secret` rather than a `%{key => Secret.t()}` map, and a reveal or hide no longer calls
`stream_insert/3` because no row markup depends on reveal state. Row 11 keeps its number and its
ADR — its `SecretRef`-only stream guarantee, its `Scope.audit_user/1` decision, and its `$callers`
sink fallback all still stand. Read `0011` then `0012`, in that order.

A wholly overturned decision is recorded here in full: the decision, the date, what replaced it,
and why. A superseded row keeps its number and moves here rather than being edited in place, so
the ADR it points at stays findable.

## Onboarding Checklist

- [ ] Read the Decision Index above; `adr/0001`–`0016` are binding
- [ ] New formal ADRs belong in `docs/adr/`, with only an index row mirrored here — the wiki's
      ADR-0001–0007 are reference only, not adopted
- [ ] Know which decisions are pending (see `living-notes.md`)

## Related Files

- `technical-domain.md` - Technical implementation affected by these decisions
- `business-tech-bridge.md` - How decisions connect business and technical
- `living-notes.md` - Current open questions that may become decisions
- `docs/adr/` - Formal ADR documents for this project, with full context/rationale/alternatives
