<!-- Context: workflows/guides | Priority: medium | Version: 1.0 | Updated: 2026-08-07 -->

# Dispatching Several Tickets at Once

> How to run more than one ticket in parallel without the branches fighting each other.
> Single-ticket delivery is in `ticket-delivery.md`.

## The Real Constraint Is the Dependency Graph

Worktrees give **filesystem** isolation. They do nothing about two agents independently
inventing the same module. That failure merges cleanly and is still wrong, which makes it far
more expensive than a textual conflict.

So dispatch in **waves**. A wave is a set of tickets that touch disjoint concerns *and* depend
only on work already merged to `origin/main`.

## Computing a Wave

```sh
gh issue list --state open --limit 100 --json number,title,labels \
  --jq '.[] | select([.labels[].name] | index("blocked") | not)
            | "\(.number)\t\(.title)\t\([.labels[].name]|join(","))"'
```

Then narrow by hand — the labels are necessary, not sufficient:

1. **Drop `blocked`** — its dependency hasn't landed.
2. **Drop `needs-decision`** — its plan is about to change.
3. **Drop anything that defines an interface another candidate implements.** Dispatch it alone
   in an earlier wave. This is the check the labels cannot make for you: read the ticket bodies
   and look for one ticket *defining* what another *implements*.
4. **Drop anything whose files obviously overlap** — two tickets both rewriting the router.

A ticket that defines a behaviour always gets a wave to itself.

## Worked Example

`EN-2` defined the backend behaviours and neutral error kinds. `EN-3` (tenant API adapter) and
`EN-4` (secrets store adapter) both *implement* them.

```
wave 1   EN-2                        alone — defines the behaviours
wave 2   EN-3, EN-5, EN-6            implement/extend against a now-fixed interface
wave 3   EN-7, EN-8                  shell and harness, once the boundaries exist
never    SEC-S1..S7                  labelled `blocked`
hold     EN-4                        labelled `needs-decision`
```

Had EN-3 and EN-4 gone out alongside EN-2, all three would have invented `Nucleus.Backend`.

## Dispatching

`/dispatch` proposes a wave, waits for your approval, then bootstraps a worktree per ticket and
prints one launch line each. You open the sessions:

```sh
cd .worktrees/en-3 && opencode      # then: /start EN-3
cd .worktrees/en-5 && opencode      # then: /start EN-5
```

Each session is independent: own directory, own branch, own context, own `deps/` and `_build/`.

### Why Not Unattended

`opencode run --dir <path> --agent build --auto "<prompt>"` will run a ticket headlessly, and
`/dispatch` can emit those lines instead. Understand the trade before using it: `--auto`
approves every permission, and a headless agent that hits an ambiguity **guesses rather than
asks**. On tickets with any design latitude that is how you get four adapters with four
different error-handling conventions. Reserve it for genuinely mechanical work.

## Costs Per Worktree

- One `mix deps.get` plus a full cold compile — deps cannot be shared, `mix.lock` diverges.
- Full source tree plus `_build/` on disk.
- One concurrent model session, billed separately.

Three or four parallel tickets is usually the practical ceiling before review becomes the
bottleneck.

## Reconciliation Order

Merge in **dependency order, not completion order**, and re-run `mix precommit` in each
remaining worktree after every merge:

```sh
git -C .worktrees/en-5 fetch origin && git -C .worktrees/en-5 rebase origin/main
cd .worktrees/en-5 && mix precommit
```

A wave-2 ticket that passed against yesterday's `main` is not known-good against a `main` that
has since absorbed its siblings. Skipping this is how a green wave turns into a red `main`.

## Related Files

- **Single-ticket delivery** → `ticket-delivery.md`
- **Answering a question/decision on a ticket** → `ticket-decisions.md`
- **Requirement traceability** → `../../project-intelligence/business-tech-bridge.md`
