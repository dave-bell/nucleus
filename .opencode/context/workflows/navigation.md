<!-- Context: workflows/nav | Priority: high | Version: 1.2 | Updated: 2026-08-14 -->

# Workflows

> Process conventions for how work moves through this project — tickets, decisions, delivery,
> and issue hygiene. Not code standards; those live in `AGENTS.md` at the project root.

## Structure

```
.opencode/context/workflows/
├── navigation.md              # This file
└── guides/
    ├── ticket-decisions.md    # Answering questions/decisions on a ticket
    ├── ticket-delivery.md     # Taking a ticket from ready to merged
    └── parallel-dispatch.md   # Running several tickets at once
```

## Guides

| File | Description | Priority |
|------|-------------|----------|
| `guides/ticket-decisions.md` | Answering a question or confirming a decision on a GitHub issue: the comment-then-unlabel loop, comment template, when to edit the issue body, ADR timing | high |
| `guides/ticket-delivery.md` | Implementing a ticket end to end: readiness gate, worktree isolation via `bin/wt`, branch naming, commit style, writing the durable record, `mix precommit` gate, opening a pull request, merging, cleanup | high |
| `guides/parallel-dispatch.md` | Working several tickets simultaneously: computing dependency-safe waves, one worktree per ticket, headless `opencode run` trade-offs, merge/rebase reconciliation order | medium |

## Loading Strategy

**Answering a question or decision on a ticket** (`EN-n`, `SEC-Sn`, `needs-decision`,
`question`):
1. Load `guides/ticket-decisions.md`
2. Read the issue itself: `gh issue view <n> --comments`

**Starting or implementing a ticket** (branch, worktree, commit, PR, merge):
1. Load `guides/ticket-delivery.md`
2. Read the issue itself: `gh issue view <n> --comments`
3. Then `AGENTS.md` and `../project-intelligence/navigation.md` for how to build it

**Dispatching multiple tickets in parallel** (waves, several worktrees):
1. Load `guides/parallel-dispatch.md`
2. Then `guides/ticket-delivery.md` for the per-ticket mechanics

**Recording a decision that has already been implemented**:
1. Load the `durable-record` skill — it writes the ADR, `decisions-log.md`,
   `business-tech-bridge.md`, and `living-notes.md`, and is invoked by `/pr` before the PR opens
2. `guides/ticket-decisions.md` (Timing section) for why those artifacts are not written at
   decision time

## Tooling

- `bin/wt` — creates/removes the per-ticket worktree under `.worktrees/<id>/`. Resolves ticket
  IDs by issue **title**, branches from `origin/HEAD`, initialises submodules, runs
  `mix deps.get`. Run `bin/wt --help`.
- Commands: `/start`, `/dispatch`, `/pr`, `/land` in `.opencode/commands/`.
- Skills: `workspace-isolation` checks for worktree isolation before implementation begins;
  `durable-record` writes the ADR and context-file updates into the ticket's PR.

## Maintenance

- Add a row to the Guides table whenever a workflow file is added — `context-indexer` routes on
  this table's text, so descriptions must use the vocabulary a real prompt would use.
- Update `../navigation.md` if this folder is renamed or removed.

## Related Files

- **Code standards** → `AGENTS.md` at the project root (authoritative for Elixir/Phoenix/LiveView)
- **Decision log** → `../project-intelligence/decisions-log.md`
- **Context root** → `../navigation.md`
