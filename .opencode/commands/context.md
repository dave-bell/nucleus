---
allowed-tools:
- Read
- Write
- Edit
- Grep
- Glob
- Bash
- Agent
argument-hint: '[discover|fetch|harvest|extract|compress|organize|cleanup|process]
  [target]'
arguments:
- operation
- target
description: Run a context-system maintenance operation — discover, fetch, harvest,
  extract, compress, organize, cleanup, or a full guided process — against this project's
  context tree.
---

# Context

Operation: $operation. Target: $target.

Load the `context-manager` skill (`.claude/skills/context-manager/SKILL.md`, `.agents/skills/context-manager/SKILL.md`, or wherever it landed) and follow its "8 Operations" section for the requested operation. It maps each operation to the exact reference file (or agent) to use.

## Default Behavior (no operation given)

1. Resolve `{context_root}` via the context-root-discovery protocol.
2. Scan the workspace root and `.tmp/` for likely harvest candidates: analysis/summary/brainstorm files not yet folded into permanent context.
3. If candidates are found, report them and ask whether to run HARVEST now.
4. If none are found, report that context looks current and suggest DISCOVER if the user is looking for something specific instead.

## Critical Rules (apply regardless of operation)

1. **MVI compliance** — every context file stays under its type's size limit (see the skill's `references/engine/standards/mvi.md`).
2. **Approval gate** — never delete or archive files without showing a lettered choice (A/B/C/"all") first. This applies to HARVEST cleanup and CLEANUP operations specifically.
3. **Function-based structure** — `concepts/`, `examples/`, `guides/`, `lookup/`, `errors/` only for new areas.
4. **Lazy load** — read only the specific operation reference file needed; don't load the entire `references/` tree up front.

## Delegation

- DISCOVER → `Agent(context-indexer)` for structured lookups, or `Agent(context-retriever)` if the repo has no formal context system yet.
- FETCH → `Agent(external-lookup)`.
- Anything that generates or restructures files (HARVEST's extract step, ORGANIZE's move step, new context creation) → `Agent(context-organizer)`.
- Cataloging, validating, and lifecycle tracking (health checks, dependency checks) → `Agent(context-manager)`.

Report results in the format the invoked operation's reference file specifies (each operation file under `references/engine/operations/` ends with an example output block).