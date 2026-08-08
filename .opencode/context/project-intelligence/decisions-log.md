<!-- Context: project-intelligence/decisions | Priority: high | Version: 1.1 | Updated: 2026-08-07 -->

# Decisions Log

> Record major architectural and business decisions with full context. This prevents "why was this done?" debates.

## Quick Reference

- **Purpose**: Document decisions so future team members understand context
- **Format**: Each decision as a separate entry
- **Status**: Decided | Pending | Under Review | Deprecated

## Decision Index

| # | Decision | Date | Status | ADR |
|---|----------|------|--------|-----|
| 1 | No local datastore — drop `ecto_sql`/`postgrex`, keep `ecto` for changesets | 2026-08-07 | Decided | `docs/adr/0001-no-local-datastore.md` |

Two things this file deliberately does **not** contain:

1. **No "re-platform" decision.** This project is a fresh start, not a migration from
   anything. The earlier prototype's architecture was never adopted here, so there is nothing
   to supersede.
2. **No inherited ADRs.** `docs/requirements/` contains `ADR-0001`–`ADR-0007` from the
   earlier prototype. They are **reference material only** and carry no status in this
   project. If one of them turns out to be right for this codebase, make that decision here
   or in `docs/adr/` on its own merits — do not import it by citation.

**Where new ADRs go**: `docs/adr/` is the home for this project's own architecture decision
records. Keep this file as the index and the narrative context; put formal ADR documents in
`docs/adr/`.

**Next decision likely needed** (tracked as an open question in `living-notes.md`): how token
passthrough works across a long-lived LiveView socket.

## Decision Template

```markdown
## [Decision Title]

**Date**: YYYY-MM-DD
**Status**: [Decided/Pending/Under Review/Deprecated]
**Owner**: [Who owns this decision]

### Context
[What situation prompted this decision? What was the problem or opportunity?]

### Decision
[What was decided? Be specific about the choice made.]

### Rationale
[Why this decision? What were the alternatives and why were they rejected?]

### Alternatives Considered
| Alternative | Pros | Cons | Why Rejected? |
|-------------|------|------|---------------|
| [Alt 1] | [Pros] | [Cons] | [Why not chosen] |
| [Alt 2] | [Pros] | [Cons] | [Why not chosen] |

### Impact
**Positive**: [What this enables or improves]
**Negative**: [What trade-offs or limitations this creates]
**Risk**: [What could go wrong]

### Related
- [Links to related decisions, PRs, issues, or documentation]
```

---

## Decision: No Local Datastore

**Date**: 2026-08-07
**Status**: Decided
**Owner**: @dave-bell (decided on issue #1, EN-1)

### Context
`mix phx.new` scaffolded a `Nucleus.Repo`, `ecto_sql`, `postgrex`, `priv/repo/`, per-environment
database config and SQL sandbox test plumbing. Nothing used any of it — no schema, no
migration, no query. This contradicted the stateless constraint adopted from the wiki Core
model ("Nucleus holds no database of its own"). A live repo in the supervision tree is an
invitation to "just cache the secret" or "just store the audit log locally". It also forced a
PostgreSQL dependency on local setup and CI for zero benefit. The decision was forced by
sequencing: SEC-S6 (#14) builds a validated form and needed to know whether `Ecto.Changeset`
would be available.

### Decision
Drop the database, keep the changeset library. Removed `ecto_sql`, `postgrex`, `Nucleus.Repo`,
`priv/repo/`, all database configuration, the `Phoenix.Ecto.CheckRepoStatus` plug, the dead
`nucleus.repo.query.*` telemetry metrics, and the test sandbox plumbing. Retained `ecto`
(now an explicit dependency) and `phoenix_ecto`.

### Rationale
`Ecto.Changeset` and `embedded_schema` are the idiomatic way to build a validated Phoenix
form, and `AGENTS.md` mandates driving forms through `to_form/2`, for which `phoenix_ecto`
supplies the `Phoenix.HTML.FormData` implementation. None of that needs a database, repo,
adapter or migration.

### Alternatives Considered
| Alternative | Pros | Cons | Why Rejected? |
|-------------|------|------|---------------|
| Keep Postgres, narrow the stateless constraint | Persistence available if later needed | Contradicts binding requirements; nothing in scope needs it | The constraint comes from requirements, not preference |
| Drop `ecto` entirely too | One less dependency | Forces hand-rolled `to_form(params, errors: ...)` in every validating form | Costs real plumbing in SEC-S6 for no gain — `ecto` alone pulls in no DB machinery |
| Leave the repo in place but unstarted | Smallest diff | Keeps dependency, config and setup burden while being non-functional and misleading | Worst of both options |

### Impact
- **Positive**: The stateless constraint is structurally enforced, not merely documented. No
  PostgreSQL for dev or CI. `ConnCase` needs no setup and can run `async: true`. EN-8 has no
  sandbox plumbing to wrap. SEC-S6 proceeds with `embedded_schema` + `Ecto.Changeset`.
- **Negative**: Audit records must go to an external log pipeline (EN-5); there is no local
  option. `Phoenix.LiveDashboard`'s Ecto stats page is inert and emits a dependency-level
  compile warning about `Postgrex.Interval`.
- **Risk**: A future contributor re-adding `ecto_sql` to get a repo back is reopening this
  decision and should say so explicitly.

### Related
- Issue #1 (EN-1) — the deciding issue and full removal plan
- `docs/adr/0001-no-local-datastore.md` — the formal ADR
- Issue #14 (SEC-S6) — consumer of the retained changeset support
- Issue #5 (EN-5) — owns where audit records actually go

---

## Deprecated Decisions

Decisions that were later overturned (for historical context):

| Decision | Date | Replaced By | Why |
|----------|------|-------------|-----|
| *(none — no decision has been overturned yet)* | — | — | — |

## Onboarding Checklist

- [ ] Read the Decision Index above; `adr/0001` (no local datastore) is binding
- [ ] Know that the wiki's ADR-0001–0007 are reference only, not adopted
- [ ] Know that new formal ADRs belong in `docs/adr/`
- [ ] Know which decisions are pending (see `living-notes.md`)

## Related Files

- `technical-domain.md` - Technical implementation affected by these decisions
- `business-tech-bridge.md` - How decisions connect business and technical
- `living-notes.md` - Current open questions that may become decisions
- `docs/adr/` - Formal ADR documents for this project
