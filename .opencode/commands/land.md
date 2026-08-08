---
description: Land a merged ticket — merge the PR, tear down the worktree and branch, then write the ADR and decision-log entries that are authored at implementation time.
agent: build
---

# Land Ticket

Ticket: $ARGUMENTS

Complete a ticket after review. This command both merges **and** writes the durable record —
per `ticket-decisions.md`, the ADR and decision-log entries are authored at implementation time,
not decision time. Skipping step 5 is how the reasoning gets lost.

## 1. Resolve and check

Resolve the ticket by issue **title**, then:

```sh
gh pr list --state open --json number,title,headRefName,mergeable,reviewDecision
gh pr checks <pr>
```

Stop and report if the PR is not mergeable, or if checks are failing or still running.

## 2. Merge

Confirm with the user before merging — this is irreversible.

```sh
gh pr merge <pr> --squash --delete-branch
```

Squash matches the existing history: one commit per ticket, sentence-style subject, lower-case,
trailing full stop. Verify `Closes #<n>` did its job:

```sh
gh issue view <n> --json state --jq .state
```

If the issue is still `OPEN`, close it with a comment pointing at the merge commit.

## 3. Tear down the worktree

Only from the **main checkout** — `bin/wt` refuses otherwise. If you are currently inside the
ticket worktree, report the `cd` the user needs and stop; you cannot remove the worktree you are
standing in.

```sh
cd <main checkout> && git pull && bin/wt --remove $ARGUMENTS
```

`bin/wt --remove` checks for uncommitted changes, untracked files, and unpushed commits before
forcing the removal. `--force` is unavoidable here — plain `git worktree remove` refuses on
worktrees containing submodules — which is exactly why those checks exist. If it refuses, do not
work around it; report what it found.

Then delete the local branch if it survived:

```sh
git branch -d <branch>
```

## 4. Verify the merge is green

```sh
mix precommit
```

On `main`, post-merge. A wave of individually-green tickets can still produce a red `main`.
If it fails, say so immediately — that is more urgent than the paperwork below.

## 5. Write the durable record

Now, and only now:

1. **ADR** — if the ticket settled an architectural choice, add `docs/adr/NNNN-<slug>.md`
   following the structure of the existing ADRs in that directory. Read one first; match it.
   Number sequentially. If the ticket settled nothing architectural, skip this and say so.
2. **Decision log** — mirror it into
   `.opencode/context/project-intelligence/decisions-log.md`.
3. **Traceability** — if the requirement mapping changed, update
   `.opencode/context/project-intelligence/business-tech-bridge.md`.
4. **Living notes** — if the work opened or closed a question, update
   `.opencode/context/project-intelligence/living-notes.md`.

Respect the MVI size limits on those context files. If an entry would push a file over, load the
`context-manager` skill and compact rather than letting it sprawl.

## 6. Propagate

If any open ticket's plan branched on this outcome, add the one-line back-reference described in
`ticket-decisions.md`, or the decision is invisible from the ticket that depends on it:

```
Resolved by #3: tenant API adapter landed, use Nucleus.TenantApi behaviour.
```

Also remove the `blocked` label from any ticket this unblocked.

## 7. Report

Merge commit, issue state, worktree/branch teardown result, `mix precommit` on `main`, files
written in step 5, and tickets updated in step 6.
