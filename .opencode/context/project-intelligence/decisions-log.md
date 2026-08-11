<!-- Context: project-intelligence/decisions | Priority: high | Version: 1.2 | Updated: 2026-08-11 -->

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

Two things this file deliberately does **not** contain:

1. **No "re-platform" decision.** This project is a fresh start, not a migration — the earlier
   prototype's architecture was never adopted here, so there is nothing to supersede.
2. **No inherited ADRs.** The wiki's `ADR-0001`–`ADR-0007` under `docs/requirements/` are
   **reference material only** and carry no status here. Adopting one is a decision made on
   its own merits in `docs/adr/`, not by citation.

**Next decision likely needed** (tracked in `living-notes.md`): how token passthrough works
across a long-lived LiveView socket.

## Decision Template

```markdown
## Decision: [Title]

**Date**: YYYY-MM-DD | **Status**: [Decided/Pending/Under Review/Deprecated] | **ADR**: `docs/adr/NNNN-slug.md`

[2-4 sentences: what was decided and the one-line reason. Link the ADR for context, rationale,
alternatives, and consequences — do not restate them here.]

**Related**: [issue links, related decisions]
```

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
swappable. Local implementations ship in the release with a loud boot warning; fault injection
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

## Deprecated Decisions

Decisions that were later overturned (for historical context):

| Decision | Date | Replaced By | Why |
|----------|------|-------------|-----|
| *(none — no decision has been overturned yet)* | — | — | — |

## Onboarding Checklist

- [ ] Read the Decision Index above; `adr/0001`–`0003` are binding
- [ ] Know that the wiki's ADR-0001–0007 are reference only, not adopted
- [ ] Know that new formal ADRs belong in `docs/adr/`, with only a short summary mirrored here
- [ ] Know which decisions are pending (see `living-notes.md`)

## Related Files

- `technical-domain.md` - Technical implementation affected by these decisions
- `business-tech-bridge.md` - How decisions connect business and technical
- `living-notes.md` - Current open questions that may become decisions
- `docs/adr/` - Formal ADR documents for this project, with full context/rationale/alternatives
