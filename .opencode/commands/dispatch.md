---
description: Propose a dependency-safe wave of tickets to work in parallel, then bootstrap one worktree per ticket after approval.
agent: build
---

# Dispatch Wave

Scope: $ARGUMENTS (empty = consider the whole open backlog)

Propose a wave of tickets that can be worked in parallel, get approval, then bootstrap the
worktrees. **Never create a worktree before the user has approved the wave.**

## 1. Load the rules

Load `.opencode/context/workflows/guides/parallel-dispatch.md`. It defines what makes a ticket
dispatchable and how waves are computed.

## 2. Read the backlog

```sh
gh issue list --state open --limit 100 --json number,title,labels \
  --jq '.[] | "\(.number)\t\(.title)\t\([.labels[].name]|join(","))"'
```

Confirm what's already merged, so you don't propose finished work:

```sh
git fetch --quiet origin && git log --oneline origin/HEAD -20
```

## 3. Compute the wave

Apply the filters in order:

1. Drop `blocked`.
2. Drop `needs-decision`.
3. **Drop anything that defines an interface another candidate implements.** This is the check
   labels cannot make for you — read the ticket bodies and look for one ticket *defining* what
   another *implements*. A ticket that defines a behaviour gets a wave to itself.
4. Drop anything with obvious file overlap (two tickets both rewriting the router).

Precedent to reason from: EN-2 defined the backend behaviours; EN-3 and EN-4 both implement
them. Dispatching all three together would have produced three competing versions of
`Nucleus.Backend` — a conflict that merges cleanly and is still wrong.

## 4. Propose and wait

Present the proposal as a table — ticket, issue number, why it's safe this wave, proposed branch
slug — followed by an explicit list of what you excluded and why. The exclusions matter as much
as the inclusions.

Cap the wave at 3–4 tickets unless the user asks for more; past that, review becomes the
bottleneck. Each worktree also costs a cold `mix deps.get` + compile, disk, and a separate
billed session.

**Then stop and ask for approval.** Offer a lettered choice (A/B/C/"all") so the user can trim
the wave.

## 5. Bootstrap the approved tickets

For each approved ticket, one at a time:

```sh
bin/wt <ID> <slug>
```

`bin/wt` branches from `origin/HEAD`, initialises submodules, and runs `mix deps.get`. If any
invocation fails, stop and report — do not continue to the next ticket.

## 6. Report launch lines

This session cannot enter the new worktrees. Print one block per ticket:

```
cd .worktrees/en-3 && opencode      # then: /start EN-3
```

Then state the reconciliation rule plainly: **merge in dependency order, not completion order**,
and after each merge, rebase every remaining worktree on `origin/main` and re-run
`mix precommit` there. A ticket that passed against yesterday's `main` is not known-good against
a `main` that has absorbed its siblings.

If the user explicitly asks for headless runs instead, emit
`opencode run --dir .worktrees/<id> --agent build --title "<ID>" "..."` — but state the trade
first: `--auto` approves every permission, and a headless agent that hits an ambiguity guesses
rather than asks.
