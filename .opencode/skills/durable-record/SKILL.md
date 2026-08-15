---
name: durable-record
description: Use when a ticket's implementation is committed and its durable record must be written — the ADR under docs/adr/ plus decisions-log.md, business-tech-bridge.md, and living-notes.md. Triggers on "write the ADR", "record the decision", "update decisions-log", "update living notes", "update the bridge", and runs as part of /pr before the pull request opens.
---

# Writing the Durable Record

Turn a ticket's settled decisions into the artifacts a future reader will actually find, and
commit them **into the ticket's own branch, as part of its pull request**.

**Announce at start:** "Writing the durable record before the PR."

## Timing — This Is the Rule

The record ships **inside the ticket's PR**, as its own commit on top of the implementation
commits. It is reviewed alongside the code that justifies it.

Three consequences to hold on to:

1. A ticket body that lists `docs/adr/…`, `living-notes.md`, or `business-tech-bridge.md` in its
   plan or acceptance criteria means exactly what it says — those files are deliverables of that
   ticket's PR. Read them literally.
2. `/land` no longer writes anything. If you reach `/land` and the record is missing, the PR was
   incomplete; see "If You Are Already Past the Merge" below.
3. `EN-1`/`EN-3`/`EN-5`/`EN-6`/`EN-7`/`EN-8` landed their records as follow-up commits *after*
   merge, under the previous convention. That history is a record of how it used to work, not a
   pattern to copy. Do not reproduce it.

Because `/land` squash-merges, the record and the implementation collapse into one commit on the
default branch. That is intended — the split exists for reviewability, not for history.

## Step 0: Preconditions

Do not start until all three hold:

| Check | Why |
|-------|-----|
| Implementation work is **committed**, working tree clean | The record describes what the code does; `git status` must be quiet so the record lands as its own commit |
| You are inside the ticket's worktree, not the main checkout | See the `workspace-isolation` skill |
| The issue is resolved by **title** and you have read it, with comments | `EN-n`/`SEC-Sn` IDs are not GitHub numbers; the comment thread carries decisions that amended the plan |

```sh
gh issue view <n> --comments
```

## Step 1: Decide What Applies

Not every ticket earns every artifact. Decide deliberately, and **say which you skipped and
why** — silence reads as an oversight.

| Artifact | Write it when | Skip it when |
|----------|---------------|--------------|
| `docs/adr/NNNN-<slug>.md` | The ticket settled an architectural choice, or reversed one | Pure mechanics with no choice in it — a rename, a dependency bump |
| `.opencode/context/project-intelligence/decisions-log.md` | An ADR was written | No ADR — the log is that file's index, never a standalone entry |
| `.opencode/context/project-intelligence/business-tech-bridge.md` | Requirement traceability changed — new action IDs covered, test paths now real | The change touches no requirement mapping |
| `.opencode/context/project-intelligence/living-notes.md` | The work opened, closed, or narrowed an open question, or retired an active project | Nothing on that file's lists moved |

If **nothing** applies, stop and report that. An empty record commit is noise.

## Step 2: The ADR

1. **Number from the directory, not the ticket body.** `ls docs/adr/` and take the highest
   number plus one. Ticket bodies name a number when they are written, and drift — EN-8's body
   asked for `0005-test-strategy.md` when `0005-deferred-authentication.md` already existed. The
   directory is the truth; if the body disagrees, follow the directory and note the divergence
   for the PR body.
2. **Read a neighbour first and match it.** `docs/adr/0007-secrets-store-adapter.md` is a good
   model. Structure: `# ADR-NNNN: Title`, `## Status`, `## Context`, `## Decision` (subsections
   per choice settled), `## Consequences`.
3. **Status is `Accepted — YYYY-MM-DD`, with the deciding issue linked.** Not `Proposed`.
   Merging the PR is the acceptance; a `Proposed` status would need flipping later, which is
   precisely the dangling follow-up step this convention removes.
4. **Never write that the ADR "is not yet live"** or otherwise hedge on its own status. It ships
   with the code it describes.
5. Cover what the previous convention's after-merge write-ups were good at: the alternatives
   rejected, and any correction that implementation surfaced which the plan could not have
   anticipated. Those are the parts nobody can reconstruct later.

## Step 3: `decisions-log.md`

Two edits, both required — the file is an index *and* a summary:

1. Add a row to the **Decision Index** table.
2. Add an entry below it, following the **Decision Template** documented in that file: title,
   the `**Date** | **Status** | **ADR**` line, two to four sentences, then `**Related**` with
   issue links.

Summarise; do not restate the ADR. Rationale, alternatives, and consequences live in the ADR and
belong in exactly one place.

## Step 4: `business-tech-bridge.md` and `living-notes.md`

Only where step 1 said they apply. Edit in place, following each file's existing entry shape —
`living-notes.md` in particular distinguishes Active Projects from its Archive, and closing an
item means moving it, not deleting it.

## Step 5: Context-File Hygiene

- Bump `Version:` and `Updated:` in the `<!-- Context: … -->` header comment of every context
  file you touched.
- Respect the MVI size limits. If an entry would push a file over, load the `context-manager`
  skill and compact — do not let it sprawl.

## Step 6: Commit

One commit, separate from the implementation, sentence-style and lower-case with a trailing full
stop, naming the artifacts written:

```
record the secrets store adapter decision: adr-0007, decisions-log, living-notes.
```

No ticket ID in the subject — the PR carries the link.

## Step 7: Hand Back

Report the files written, the ADR number assigned, anything you skipped and why, and any place
the ticket body disagreed with what you found. `/pr` folds that into the PR body, so the
reviewer sees the record and the code together.

## If You Are Already Past the Merge

A ticket that merged without its record is not a reason to leave the record unwritten. Write it
on the default branch as a standalone commit, and say plainly that it is a repair of a missed
step, not the normal flow.

## Related

- **Delivery mechanics, PR conventions** → `.opencode/context/workflows/guides/ticket-delivery.md`
- **Decision-time vs implementation-time artifacts** → `.opencode/context/workflows/guides/ticket-decisions.md`
- **Compacting an oversized context file** → `context-manager` skill
