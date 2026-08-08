---
description: Open a pull request for the current ticket branch — verify the precommit gate, delegate the body to the pr-author subagent, then create it.
agent: build
---

# Open Pull Request

Ticket: $ARGUMENTS (empty = infer from the current branch name)

## 1. Establish where you are

```sh
git branch --show-current
git rev-parse --show-toplevel
git fetch --quiet origin
```

Stop and report if:

- You are on the default branch. PRs come from ticket branches.
- There are no commits ahead of `origin/HEAD` — nothing to open a PR for.
- The working tree is dirty. Commit or stash first; a PR must describe committed work.

If `$ARGUMENTS` is empty, infer the ticket ID from the branch name (`en-3-...` → `EN-3`) and
state the inference you made.

## 2. Verify the gate

Run `mix precommit` in this worktree. It is `compile --warnings-as-errors`,
`deps.unlock --unused`, `format`, `test`.

**If it fails, stop.** Report the failure and offer to fix it. Never open a PR on a red gate.

If `mix format` or `deps.unlock` modified files, commit those changes before continuing.

## 3. Push

```sh
git push -u origin HEAD
```

## 4. Delegate the body

Invoke the `pr-author` subagent with the ticket ID and base ref. It reads the diff and the issue
in an isolated context and returns markdown only — this keeps a large diff out of this session.

Do not write the body yourself unless `pr-author` is unavailable.

## 5. Create the PR

Review what came back before using it. Check specifically that:

- `Closes #<number>` is present and the number matches the issue you resolved by **title**.
- Any `## Divergence from the plan` section is accurate — this is the highest-value part for a
  reviewer, and the easiest to get wrong.
- No claim is made about tests passing beyond what step 2 actually showed.

Then:

```sh
gh pr create --base <default-branch> --title "<ID>: <short description>" --body-file -
```

Pass the body on stdin. Do not use `--fill`.

## 6. Report

Return the PR URL, the issue it closes, and the `mix precommit` result. If you amended anything
`pr-author` produced, say what and why.
