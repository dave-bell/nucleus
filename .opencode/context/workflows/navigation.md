<!-- Context: workflows/nav | Priority: high | Version: 1.0 | Updated: 2026-08-07 -->

# Workflows

> Process conventions for how work moves through this project — tickets, decisions, and issue
> hygiene. Not code standards; those live in `AGENTS.md` at the project root.

## Structure

```
.opencode/context/workflows/
├── navigation.md              # This file
└── guides/
    └── ticket-decisions.md    # Answering questions/decisions on a ticket
```

## Guides

| File | Description | Priority |
|------|-------------|----------|
| `guides/ticket-decisions.md` | Answering a question or confirming a decision on a GitHub issue: the comment-then-unlabel loop, comment template, when to edit the issue body, ADR timing | high |

## Loading Strategy

**Answering a question or decision on a ticket** (`EN-n`, `SEC-Sn`, `needs-decision`, `question`):
1. Load `guides/ticket-decisions.md`
2. Read the issue itself: `gh issue view <n> --comments`

**Recording a decision that has already been implemented**:
1. Load `guides/ticket-decisions.md` (Timing section — issue vs ADR vs log)
2. Then `../project-intelligence/decisions-log.md`

## Maintenance

- Add a row to the Guides table whenever a workflow file is added — `context-indexer` routes on
  this table's text, so descriptions must use the vocabulary a real prompt would use.
- Update `../navigation.md` if this folder is renamed or removed.

## Related Files

- **Code standards** → `AGENTS.md` at the project root (authoritative for Elixir/Phoenix/LiveView)
- **Decision log** → `../project-intelligence/decisions-log.md`
- **Context root** → `../navigation.md`
