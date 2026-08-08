<!-- Context: workflows/guides | Priority: high | Version: 1.0 | Updated: 2026-08-07 -->

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

`mix precommit` is the required gate — `compile --warnings-as-errors`, `deps.unlock --unused`,
`format`, `test`. Run it **inside the worktree**. Never open a PR on a red gate.

## Pull Request

`/pr` delegates the body to the `pr-author` subagent, then creates it. The body must:

- Open with what changed and why, in prose — not a bullet dump of the diff.
- Carry `Closes #<number>` so the merge closes the issue automatically.
- Call out any divergence from the plan in the issue body, and why.
- Name the requirement IDs (`SEC-A09`, …) the change satisfies, where relevant.

## After Merge

`/land` squash-merges, deletes the branch, and removes the worktree. Then, and **only** then,
write the durable record — per `ticket-decisions.md`, these are authored at implementation
time, not decision time:

1. `docs/adr/NNNN-<slug>.md` — what we do now, if the ticket settled an architectural choice.
2. `project-intelligence/decisions-log.md` — the in-repo mirror.
3. `project-intelligence/business-tech-bridge.md` — if requirement traceability changed.

## Worktree Teardown

`git worktree remove` **refuses outright** on worktrees containing submodules, so `--force` is
mandatory — which also discards uncommitted work. Use `bin/wt --remove EN-3`: it checks for
uncommitted changes, untracked files, and unpushed commits before forcing.

## Related Files

- **Answering a question/decision on a ticket** → `ticket-decisions.md`
- **Running several tickets at once** → `parallel-dispatch.md`
- **Code standards** → `AGENTS.md` at the project root
- **Decision log** → `../../project-intelligence/decisions-log.md`
- **Requirement traceability** → `../../project-intelligence/business-tech-bridge.md`
