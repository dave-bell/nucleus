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
| 2 | Backend adapter boundaries — behaviours, tagged-tuple errors, per-boundary real/local selection | 2026-08-07 | Decided | `docs/adr/0002-backend-adapter-boundaries.md` |

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

## Decision: Backend Adapter Boundaries

**Date**: 2026-08-07
**Status**: Decided
**Owner**: @dave-bell (decided on issue #2, EN-2)

### Context
Secrets reads from two external systems: the tenant's AWS SSM Parameter Store (the secrets) and
the tenant's backing API (the authoritative environment list used to validate environment names
before any parameter path is built). Parameter Store access needs a Terraform-provisioned
cross-account IAM role, so calling it directly means a fresh clone cannot run and CI cannot
test — even for a developer touching only environment listing. The earlier prototype also
leaked backend-specific failures into route code (an SSM `CredentialsExpiredError` caught in a
route, `KeyError` reused for two meanings), which makes the "pluggable backends" constraint in
`technical-domain.md` documentation rather than fact.

### Decision
Every external system sits behind an Elixir **behaviour** with two implementations, `real` and
`local`, selected **per boundary** via `config :nucleus, :backends` — real in `config.exs`,
local in `dev.exs`/`test.exs`, overridable at runtime with `SECRETS_BACKEND` and
`TENANT_API_BACKEND` (`"real"` | `"local"`). Callbacks return
`{:error, %Nucleus.Backend.Error{}}` — **returned, never raised** — carrying one of six neutral
`kind`s (`:invalid`, `:not_found`, `:already_exists`, `:auth_expired`, `:unavailable`,
`:not_configured`). Every behaviour declares `health_check/0`. There is no `:auth` boundary and
no `AUTH_BACKEND`; auth is never swappable. Local implementations ship in the release, with a
prominent boot warning naming any boundary serving in-memory data.
`Nucleus.Backend.Faults.maybe_fault/1` (`LOCAL_LATENCY_MS`, `LOCAL_FORCE_ERROR`) is required,
not optional.

### Rationale
Behaviours are the Elixir idiom for a swappable interface, and `@behaviour` plus
`compile --warnings-as-errors` catches signature drift at build time — no separate conformance
checker needed. Tagged tuples keep the failure path visible and exhaustively matchable; `rescue`
in a `handle_event/3` cannot be either. Six kinds instead of the prototype's five splits
`:invalid` (input rejected before any backend call) out from backend failure, which is precisely
the conflation that made `KeyError` mean two things. Per-boundary selection matches the shape of
the cost being avoided. Fault injection is what makes `SEC-S1` (fail closed) and `SEC-S7`
(credential expiry) testable at all.

### Alternatives Considered
| Alternative | Pros | Cons | Why Rejected? |
|-------------|------|------|---------------|
| Direct `ExAws`/`Req` calls, no boundary | Least code | No way to run without live infra; backend exception types reach LiveViews | The exact state the prototype was leaving |
| Single global `BACKEND_MODE` | One switch to explain | All-or-nothing when only Parameter Store is expensive to access | The cost is per boundary, so the switch should be |
| Raise `Nucleus.Backend.Error` instead of returning it | Terser call sites | `rescue` in `handle_event/3` is unverifiable and needed everywhere | Failure handling must be exhaustively matchable |
| Exclude local implementations from the release build | Local mode physically impossible in prod | Build stage and package list must stay in sync; a mistake breaks dev silently | Auth is never swappable, so the risk is wrong data, not bypass — a boot warning is proportionate |
| `Mox`/`Hammox` instead of local implementations | No second implementation to maintain | Mocks exist only for tests and drift from what a developer can run | One local implementation serves both dev and test |
| Detect "local" from the module name suffix | No registry to maintain | Stringly-typed; defeated by a rename | Explicit registry costs two lines per boundary |

### Impact
- **Positive**: A fresh clone runs and the whole suite passes with zero credentials and no
  external services. CI needs no dummy env vars. LiveViews match on `Error.kind`, so a backend
  is replaceable without touching business logic. `health_check/0` closes the readiness
  boundary violation before it can happen. `Error.kinds/0` is asserted against the `@type kind`
  union, so a seventh kind cannot be added silently.
- **Negative**: Two implementations per boundary to keep in agreement — EN-8 owns the shared
  contract suite, which still cannot catch every nuance (real SSM's eventual consistency).
  `impl_for/1` raises for both boundaries until EN-3/EN-4 land, by design and by name. Every
  `mix test` run logs the local-backends warning once.
- **Risk**: Token passthrough over a long-lived LiveView socket is still unresolved and shapes
  the callback *arguments* EN-3/EN-4 define. This decision fixes only the return shape.

### Related
- Issue #2 (EN-2) — the deciding issue and full implementation plan
- `docs/adr/0002-backend-adapter-boundaries.md` — the formal ADR
- Issues #3 (EN-3), #4 (EN-4) — the concrete boundaries built on this scaffolding
- Issue #6 (EN-6) — auth, deliberately outside the boundary set
- Issue #8 (EN-8) — the contract test harness
- `docs/adr/0001-no-local-datastore.md` — local implementations are in-memory per process, never
  persisted

---

## Deprecated Decisions

Decisions that were later overturned (for historical context):

| Decision | Date | Replaced By | Why |
|----------|------|-------------|-----|
| *(none — no decision has been overturned yet)* | — | — | — |

## Onboarding Checklist

- [ ] Read the Decision Index above; `adr/0001` (no local datastore) and
      `adr/0002` (backend adapter boundaries) are binding
- [ ] Know that the wiki's ADR-0001–0007 are reference only, not adopted
- [ ] Know that new formal ADRs belong in `docs/adr/`
- [ ] Know which decisions are pending (see `living-notes.md`)

## Related Files

- `technical-domain.md` - Technical implementation affected by these decisions
- `business-tech-bridge.md` - How decisions connect business and technical
- `living-notes.md` - Current open questions that may become decisions
- `docs/adr/` - Formal ADR documents for this project
