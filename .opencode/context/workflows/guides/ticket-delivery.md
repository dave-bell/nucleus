<!-- Context: workflows/guides | Priority: high | Version: 1.1 | Updated: 2026-08-14 -->

# Delivering a Ticket

> From a ready ticket to merged code: isolation, branch, commits, PR, cleanup. For *answering
> a question* on a ticket instead, see `ticket-decisions.md`.

## Resolve the Ticket First

`EN-n` and `SEC-Sn` IDs live in the issue **title**, not the GitHub number. `SEC-S1` is issue
**#9**. Never assume the ID equals the number. `bin/wt` resolves by title prefix; do the same
by hand with:

```sh
gh issue list --state all --limit 200 --json number,title \
  --jq '.[] | select(.title | startswith("EN-3:")) | "\(.number)\t\(.title)"'
```

## Readiness Gate

Do **not** start a ticket carrying either label:

| Label | Meaning | Do this instead |
|-------|---------|-----------------|
| `needs-decision` | An open question blocks the plan | Answer it via `ticket-decisions.md`, then start |
| `blocked` | A dependency hasn't landed | Deliver the dependency first |

Starting a `needs-decision` ticket means implementing a plan that is about to change. `bin/wt`
warns on both but does not refuse — the judgement is yours.

## Isolation

One worktree per ticket, under `.worktrees/<id>/` (gitignored):

```sh
bin/wt EN-3 tenant-api-adapter    # -> .worktrees/en-3, branch en-3-tenant-api-adapter
cd .worktrees/en-3 && opencode
```

Three things `bin/wt` handles that manual `git worktree add` does not:

1. **Branches from `origin/HEAD`, not current HEAD.** Branching off a feature branch inherits
   its unmerged work — the result merges cleanly and is still wrong.
2. **Initialises submodules.** `git worktree add` leaves `docs/requirements/` empty, so the
   ticket loses the requirements it traces to.
3. **Runs `mix deps.get` per worktree.** `deps/` and `_build/` cannot be shared: `mix.lock`
   diverges across branches (EN-1 dropped `ecto_sql`/`postgrex`).

## Branch Naming

`<id-lower>-<slug>`, where the slug **describes the work**, not the ticket title:

```
en-1-no-local-datastore     <- "EN-1: Resolve Postgres-vs-stateless — drop ecto_sql/postgrex"
en-2-backend-boundary-foundation
```

Pass the slug explicitly. The title-derived default is a fallback and often a poor description.

## Commits

Sentence-style, lower-case, trailing full stop — matching the existing log:

```
add the backend boundary foundation: behaviours, neutral errors, real/local selection.
remove postgres and the ecto repo, keep ecto for changesets.
```

Do not put ticket IDs in commit subjects. The PR carries the link.

## Before Opening a PR

Two required steps, in this order.

**1. Write the durable record.** Load the `durable-record` skill. If the ticket settled an
architectural choice, `docs/adr/NNNN-<slug>.md` and the `decisions-log.md` entry are part of
**this ticket's PR** — plus `business-tech-bridge.md` where traceability changed and
`living-notes.md` where a question opened or closed. They go in as their own commit on top of the
implementation, so a reviewer sees the reasoning next to the code.

This means a ticket body listing doc updates in its plan or acceptance criteria is read
**literally**: those files belong in that ticket's diff. `EN-1`/`EN-3`/`EN-5`/`EN-6`/`EN-7`/`EN-8`
each landed their record as a follow-up commit *after* merge under the previous convention — that
is history, not a pattern to copy.

**2. Run the gate.** `mix precommit` — `compile --warnings-as-errors`, `deps.unlock --unused`,
`format`, `test`. Run it **inside the worktree**, after the record commit. Never open a PR on a
red gate.

## Pull Request

`/pr` writes the record, verifies the gate, delegates the body to the `pr-author` subagent, then
creates it. The body must:

- Open with what changed and why, in prose — not a bullet dump of the diff.
- Carry `Closes #<number>` so the merge closes the issue automatically.
- Call out any divergence from the plan in the issue body, and why.
- Name the requirement IDs (`SEC-A09`, …) the change satisfies, where relevant.
- Describe the record that shipped with it, or explain why the ticket earned none.

## After Merge

`/land` squash-merges, deletes the branch, and removes the worktree. The record already merged
with the code, so there is no documentation step left — squashing collapses the implementation
commits and the record commit into the single ticket commit on the default branch.

What does remain: verify `Closes #<n>` actually closed the issue, run `mix precommit` on the
default branch (a wave of individually-green tickets can still produce a red `main`), and
propagate the outcome to any ticket whose plan branched on it, per `ticket-decisions.md`.

## Worktree Teardown

`git worktree remove` **refuses outright** on worktrees containing submodules, so `--force` is
mandatory — which also discards uncommitted work. Use `bin/wt --remove EN-3`: it checks for
uncommitted changes, untracked files, and unpushed commits before forcing.

## Related Files

- **Answering a question/decision on a ticket** → `ticket-decisions.md`
- **Writing the ADR / decision log for a ticket** → `durable-record` skill
- **Running several tickets at once** → `parallel-dispatch.md`
- **Code standards** → `AGENTS.md` at the project root
- **Decision log** → `../../project-intelligence/decisions-log.md`
- **Requirement traceability** → `../../project-intelligence/business-tech-bridge.md`
