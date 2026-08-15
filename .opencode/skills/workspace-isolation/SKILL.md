---
name: workspace-isolation
description: Use before implementing a ticket, executing a plan, or transitioning from planning to building — checks whether the current directory is an isolated git worktree and offers to create one under .worktrees/ so the main checkout stays clean. Triggers on "implement this", "go ahead and build it", "start on EN-n", "work this ticket".
---

# Workspace Isolation

Ensure implementation work happens in an isolated worktree, not the main checkout.

**Announce at start:** "Checking workspace isolation before making changes."

## Step 0: Detect Existing Isolation

```sh
GIT_DIR=$(cd "$(git rev-parse --git-dir)" && pwd -P)
GIT_COMMON=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
```

**Submodule guard — do not skip.** `GIT_DIR != GIT_COMMON` is *also* true inside a git
submodule, and this repo has one at `docs/requirements/`. Verify before concluding anything:

```sh
git rev-parse --show-superproject-working-tree 2>/dev/null
```

If that prints a path, you are in a submodule, **not** a worktree. Treat it as a normal
checkout, and note that editing files there commits to `nucleus.wiki`, not this repo.

Decide, and set `isolation_status` to one of the three values in the right column — every later
step in this skill is gated on that value, not on remembering the prose below:

| Condition | Meaning | `isolation_status` |
|-----------|---------|--------|
| Output above is non-empty | Inside the `docs/requirements` submodule | `submodule` — stop, confirm with the user, do not set any other value |
| `GIT_DIR != GIT_COMMON` | Already in a linked worktree | `already-isolated` — report path + branch, go to **Step 2** |
| `GIT_DIR == GIT_COMMON` | Main checkout | unset — go to **Step 1** |

Report as: "Already isolated at `.worktrees/en-3` on branch `en-3-tenant-api-adapter`."

## Step 1: Offer Isolation

You are in the main checkout. If the user has already stated a preference in this session,
honour it silently. Otherwise **ask before creating anything**:

> "You're in the main checkout on `main`. Set up an isolated worktree for this ticket? It keeps
> `main` clean and lets other tickets run in parallel."

If they decline: `isolation_status = declined`. Work in place and go to **Step 2**. Do not
re-ask later in the session.

If they accept, use `bin/wt` — never raw `git worktree add`:

```sh
bin/wt EN-3 tenant-api-adapter
```

`bin/wt` branches from `origin/HEAD` (not current HEAD), initialises submodules, and runs
`mix deps.get`. Doing it by hand skips all three and produces a worktree with empty
requirements and a wrong base. Run `bin/wt --help` for options.

`isolation_status = new-worktree-created`.

> [!STOP]
> **This session cannot move into the new worktree.** It is a different directory on disk; `cd`
> from this process does not change what this session can edit. Output the launch line below,
> then **end your turn. Do not call another tool. Do not read Step 2.**
>
> ```
> cd .worktrees/en-3 && opencode      # then: /start EN-3
> ```
>
> Loading `ticket-delivery.md`, running `context-indexer`, or reading the issue further in *this*
> session is not "getting a head start" — it is wasted work. A fresh session inside the new
> worktree runs `/start` again and reloads everything from the correct location. That session
> does not inherit anything you do here after this point.

## Step 2: Proceed

**Precondition — do not enter this step unless `isolation_status` is `already-isolated` or
`declined`.** If `isolation_status` is `new-worktree-created`, you already stopped at the STOP
box in Step 1; there is nothing here for that session to do.

Isolation is settled. Load `.opencode/context/workflows/guides/ticket-delivery.md` for branch
naming, commit style, the durable-record timing, the `mix precommit` gate, and PR conventions,
then begin the work.

## Related

- Delivery mechanics → `.opencode/context/workflows/guides/ticket-delivery.md`
- Several tickets at once → `.opencode/context/workflows/guides/parallel-dispatch.md`
