<!-- Context: project-intelligence/decisions | Priority: high | Version: 1.0 | Updated: 2026-08-07 -->

# Decisions Log

> Record major architectural and business decisions with full context. This prevents "why was this done?" debates.

## Quick Reference

- **Purpose**: Document decisions so future team members understand context
- **Format**: Each decision as a separate entry
- **Status**: Decided | Pending | Under Review | Deprecated

## Current State: No Decisions Recorded

**This project has made no architectural decisions yet.** The codebase is an unmodified
`mix phx.new` skeleton with no commits, so nothing has been chosen deliberately enough to
record. The template entries below are placeholders — replace them, don't add around them.

Two things this file deliberately does **not** contain:

1. **No "re-platform" decision.** This project is a fresh start, not a migration from
   anything. The earlier prototype's architecture was never adopted here, so there is nothing
   to supersede.
2. **No inherited ADRs.** `docs/requirements/` contains `ADR-0001`–`ADR-0007` from the
   earlier prototype. They are **reference material only** and carry no status in this
   project. If one of them turns out to be right for this codebase, make that decision here
   or in `docs/adr/` on its own merits — do not import it by citation.

**Where new ADRs go**: `docs/adr/` (currently empty) is the home for this project's own
architecture decision records. Keep this file as the index and the narrative context; put
formal ADR documents in `docs/adr/`.

**First decisions likely needed** (tracked as open questions in `living-notes.md`):
whether to keep Ecto/Postgres against the stateless constraint, and how token passthrough
works across a long-lived LiveView socket.

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

## Decision: [Title]

**Date**: YYYY-MM-DD
**Status**: [Status]
**Owner**: [Owner]

### Context
[What was happening? Why did we need to decide?]

### Decision
[What we decided]

### Rationale
[Why this was the right choice]

### Alternatives Considered
| Alternative | Pros | Cons | Why Rejected? |
|-------------|------|------|---------------|
| [Option A] | [Good things] | [Bad things] | [Reason] |
| [Option B] | [Good things] | [Bad things] | [Reason] |

### Impact
- **Positive**: [What we gain]
- **Negative**: [What we trade off]
- **Risk**: [What to watch for]

### Related
- [Link to PR #000]
- [Link to issue #000]
- [Link to documentation]

---

## Decision: [Title]

**Date**: YYYY-MM-DD
**Status**: [Status]
**Owner**: [Owner]

### Context
[What was happening?]

### Decision
[What we decided]

### Rationale
[Why this was right]

### Alternatives Considered
| Alternative | Pros | Cons | Why Rejected? |
|-------------|------|------|---------------|
| [Option A] | [Good things] | [Bad things] | [Reason] |

### Impact
- **Positive**: [What we gain]
- **Negative**: [What we trade off]

### Related
- [Link]

---

## Deprecated Decisions

Decisions that were later overturned (for historical context):

| Decision | Date | Replaced By | Why |
|----------|------|-------------|-----|
| *(none — no decisions have been made yet)* | — | — | — |

## Onboarding Checklist

- [ ] Understand that no decisions are recorded yet, and why that is accurate
- [ ] Know that the wiki's ADR-0001–0007 are reference only, not adopted
- [ ] Know that new formal ADRs belong in `docs/adr/`
- [ ] Know which decisions are pending (see `living-notes.md`)

## Related Files

- `technical-domain.md` - Technical implementation affected by these decisions
- `business-tech-bridge.md` - How decisions connect business and technical
- `living-notes.md` - Current open questions that may become decisions
- `docs/adr/` - Formal ADR documents for this project
