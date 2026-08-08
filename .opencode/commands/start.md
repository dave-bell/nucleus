---
description: Start work on a ticket — resolve the issue by title, check the readiness gate, ensure worktree isolation, and load the delivery conventions.
agent: build
---

# Start Ticket

Ticket: $ARGUMENTS

Begin work on this ticket. Do not write any implementation code during this command — this is
setup and orientation only. Report and stop.

## 1. Resolve the issue

IDs live in the issue **title**, not the number. `SEC-S1` is issue `#9`.

```sh
gh issue list --state all --limit 200 --json number,title \
  --jq ".[] | select(.title | startswith(\"$ARGUMENTS:\")) | \"\(.number)\t\(.title)\""
```

If nothing matches, or more than one does, stop and report it.

## 2. Readiness gate

Read the issue and its comments: `gh issue view <n> --comments`.

**Stop and report — do not proceed — if it carries either label:**

- `needs-decision` → an open question blocks the plan. Point at
  `.opencode/context/workflows/guides/ticket-decisions.md` and offer to work the decision loop
  instead.
- `blocked` → a dependency hasn't landed. Identify which ticket, and say so.

Also stop if the issue is already `CLOSED`.

## 3. Workspace isolation

Load the `workspace-isolation` skill and follow it. In short: check whether you are already in
a linked worktree (with the submodule guard — `docs/requirements` is a submodule and defeats
naive detection). If you're in the main checkout, ask before creating anything, then use
`bin/wt $ARGUMENTS <slug>` — never raw `git worktree add`.

Choose the slug to describe **the work**, not the ticket title, and propose it to the user
before running. Precedent: `en-1-no-local-datastore` for a ticket titled *"Resolve
Postgres-vs-stateless — drop ecto_sql/postgrex"*.

If `bin/wt` creates a new worktree, this session cannot move into it. Report the printed launch
line and stop.

## 4. Load context

Once isolation is settled and you are in the right directory:

1. Run `context-indexer` for this ticket's subject matter (mandated by `AGENTS.md`).
2. Load `.opencode/context/workflows/guides/ticket-delivery.md`.
3. Read any requirement pages under `docs/requirements/` that the issue references.

## 5. Report

Summarise and stop:

- Issue number, title, labels
- Worktree path and branch, and whether you created them
- The implementation plan from the issue body, restated in your own words, with any decisions
  from the comment thread folded in
- Anything in the plan you think is wrong, ambiguous, or under-specified — say so now, before
  code exists
- The context files you loaded

Then ask whether to proceed with implementation.
