<!-- Context: workflows/guides | Priority: high | Version: 1.1 | Updated: 2026-08-14 -->

# Answering Questions & Decisions on a Ticket

> How to confirm a choice, or answer a question, on a ticket — and leave a record the next
> reader can trust.

## The Ticket System

GitHub Issues on `dave-bell/nucleus`, driven by the `gh` CLI. There is no ticket-system MCP.

- `EN-n` and `SEC-Sn` IDs live in the issue **title**, not the GitHub number. Resolve by title
  match: `EN-1` is issue **#1**. Never assume the ID equals the number.
- Find open decisions: `gh issue list --label needs-decision`
- Read one: `gh issue view <n> --comments`

## The Loop

Two steps. Both required.

```sh
gh issue comment <n> --body-file -   # 1. post the decision
gh issue edit <n> --remove-label needs-decision   # 2. clear the signal
```

The comment is the permanent record of the decision. The label is the machine-readable "still
blocked on Dave" flag that `gh issue list --label needs-decision` scans. **If the label survives
the answer, the agent will re-ask.** Clearing it is not optional bookkeeping.

## Comment Template

```markdown
### Decision
Accepted as recommended — drop `ecto_sql` + `postgrex`, keep `ecto` + `phoenix_ecto`.

### Consequences
- #14 (SEC-S6) proceeds with the `embedded_schema` + changeset form approach.

Decided by @dave-bell · 2026-08-07
```

- Add `### Rationale` **only** when the decision diverges from the recommendation in the body.
  If you simply accept, the body already carries the reasoning — don't restate it.
- One comment per decision, so the chronology stays readable.

## When to Edit the Issue Body

**Only if the decision diverges from the recommendation.**

These tickets carry full implementation plans. A rejected recommendation leaves a *wrong plan*
in the body, and whoever implements it reads the body — not the comment thread. In that case:

1. Amend the affected plan sections.
2. Prepend `> Superseded by <comment-url>` to the changed section.

If you accept the recommendation, leave the body alone.

## Propagate to Downstream Tickets

Any ticket whose plan branches on the outcome gets a one-line back-reference, or the decision is
invisible from the ticket that depends on it:

```
Resolved by #1: ecto retained, use embedded_schema.
```

## Timing: Issue vs ADR vs decisions-log

| Artifact | Answers | Written |
|----------|---------|---------|
| Issue comment | *when and why we chose* | at decision time |
| `docs/adr/` | *what we do now* | at implementation time, **in the ticket's own PR** |
| `project-intelligence/decisions-log.md` | in-repo mirror of the decision | at implementation time, **in the ticket's own PR** |

Do **not** write the ADR or log entry when the decision is made — only when the work is built.
Otherwise the reasoning is duplicated in three places ahead of any code.

"At implementation time" means **before the pull request opens, as a commit in that PR** — not
after `/land` merges it. The `durable-record` skill does this, and `/pr` invokes it. A ticket body
that lists ADR or context-file updates in its plan or acceptance criteria is therefore read
literally: those files belong in that ticket's diff.

## Non-Decision Questions

Same loop, different label: the stock `question` label ("Further information is requested").
Comment the answer, then remove the label.

## Known Gap: Project Board Is Invisible

The `gh` token lacks the `read:project` scope. Consequences:

- `gh project list` and any `projectsV2` GraphQL query fail with `INSUFFICIENT_SCOPES`.
- `gh issue view <n>` renders `projects:` as **empty regardless of actual membership** — a
  tracked issue and an untracked one look identical. Do not conclude an issue is off the board.

Fix: `gh auth refresh -s project`

## Related Files

- **Writing the ADR / decision log for a ticket** → `durable-record` skill
- **Decision log** → `../../project-intelligence/decisions-log.md`
- **Open questions / debt** → `../../project-intelligence/living-notes.md`
- **Requirement traceability** → `../../project-intelligence/business-tech-bridge.md`
