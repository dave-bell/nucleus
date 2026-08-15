---
description: Land a reviewed ticket — confirm the durable record shipped in the PR, merge it, then tear down the worktree and branch.
agent: build
---

# Land Ticket

Ticket: $ARGUMENTS

Complete a ticket after review: merge, tear down, propagate.

This command **does not write the ADR or the decision log.** Those ship inside the ticket's own
PR, written by the `durable-record` skill during `/pr`. Step 1 checks they are there; if they are
not, the fix is to add them to the PR before merging, not to write them here afterwards.

## 1. Resolve and check

Resolve the ticket by issue **title**, then:

```sh
gh pr list --state open --json number,title,headRefName,mergeable,reviewDecision
gh pr checks <pr>
```

Stop and report if the PR is not mergeable, or if checks are failing or still running.

Then confirm the durable record is in the PR:

```sh
gh pr diff <pr> --name-only
```

If the ticket settled an architectural choice and no `docs/adr/` or
`project-intelligence/decisions-log.md` change appears, **stop.** Report it, and offer to write
the record onto the ticket branch via the `durable-record` skill so it merges with the code. Do
not merge first and paper over it after — that is the pattern this convention exists to end.

A ticket that genuinely settled nothing architectural is allowed to carry no record. Say so
explicitly rather than leaving it unmentioned.

## 2. Merge

Confirm with the user before merging — this is irreversible.

```sh
gh pr merge <pr> --squash --delete-branch
```

Squash matches the existing history: one commit per ticket, sentence-style subject, lower-case,
trailing full stop. The implementation commits and the record commit collapse into that one
commit — the split existed for the reviewer, not for `main`'s history. Verify `Closes #<n>` did
its job:

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
If it fails, say so immediately.

## 5. Propagate

If any open ticket's plan branched on this outcome, add the one-line back-reference described in
`ticket-decisions.md`, or the decision is invisible from the ticket that depends on it:

```
Resolved by #3: tenant API adapter landed, use Nucleus.TenantApi behaviour.
```

Also remove the `blocked` label from any ticket this unblocked.

## 6. Report

Merge commit, issue state, worktree/branch teardown result, `mix precommit` on `main`, the record
artifacts step 1 confirmed were in the PR, and tickets updated in step 5.
