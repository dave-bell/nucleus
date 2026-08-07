---
name: context-manager
description: Use when the user wants to discover, organize, validate, harvest, extract, compress, or clean up context files (project standards, project-intelligence, or labbit-configuration content). Also use when setting up a new context system from scratch, or migrating context between global and local scope.
---

# context-manager

Comprehensive context management: discovering, organizing, and maintaining the project's context system. This skill is the operational counterpart to the `context-indexer`, `context-organizer`, and `context-manager` agents — use it for the "how", delegate to those agents for the "who does the work".

## Three Tiers

This skill's `references/` is organized in three tiers — don't confuse them:

| Tier | Location | What it is |
|---|---|---|
| **Engine** | `references/engine/` | Domain-agnostic rules: MVI, frontmatter, structure, operations, navigation design. Used identically by every domain below. |
| **Software-development domain** | `references/domains/software-development/` | What to capture when building Labbit itself: `project-intelligence.md` (standard) + `project-intelligence-management.md` (management guide) + `standards/` (7 language-agnostic coding standards: code quality, testing, docs, security, analysis, clean code, API design). |
| **Labbit-configuration domain** | `references/domains/labbit-configuration/` | What to capture when configuring Labbit for a customer: `customer-intelligence.md` (standard) + `customer-intelligence-management.md` (management guide) + `standards/` (JSONC config patterns, BPMN modeling, customer config governance). |

Both domains have matching shape: a standard, a management guide, and a `standards/` directory. A domain's management guide references the engine for generic mechanics (versioning, deprecation, size limits) and only spells out what's specific to that domain — never duplicate engine rules into a domain doc, and never duplicate one domain's `standards/` content into the other's.

For the underlying standards this skill enforces, LOAD as needed:
- `references/context-root-discovery.md` — how to resolve `{context_root}` for any harness
- `references/engine/overview.md` — engine architecture overview (read this first if unsure where something belongs)
- `references/engine/standards/mvi.md` — the size/format standard every context file follows
- `references/engine/standards/frontmatter.md` — required file header
- `references/engine/standards/structure.md` — function-based folder organization
- `references/engine/standards/codebase-references.md` — linking context to real code
- `references/domains/software-development/navigation.md` — software-dev domain (project-intelligence + coding standards)
- `references/domains/labbit-configuration/navigation.md` — labbit-configuration domain (customer-intelligence + JSONC/BPMN standards)

## The 8 Operations

### 1. DISCOVER — find context files by topic or path

No dedicated reference file — this is what the `context-indexer` (structured) or `context-retriever` (unstructured/unknown repo) agents do. For a quick manual check yourself: resolve `{context_root}` (see `references/context-root-discovery.md`), then `glob`/`grep` from there.

### 2. FETCH — get external library/framework documentation

Delegate to the `external-lookup` agent, or use the `context7` skill directly for a one-off lookup. Persisted results land in `.tmp/external-context/`.

### 3. HARVEST — extract context from summary/analysis files into permanent context

LOAD `references/engine/operations/harvest.md` for the full 6-stage workflow (scan → analyze → approve → extract → cleanup → report). Use when a temporary `ANALYSIS.md`, brainstorm doc, or session summary contains knowledge that should become permanent context.

### 4. EXTRACT — pull specific information out of existing context files

LOAD `references/engine/operations/extract.md` for the 7-stage workflow (read → extract → categorize → approve → create → validate → report). Use when building a context bundle for a subagent or summarizing standards for a report.

### 5. COMPRESS — reduce oversized context files

No dedicated reference file. Apply `references/engine/standards/mvi.md` directly: split the file by concern, move detail into sibling reference files, keep the primary file to the size limit for its type (concepts <100, guides <150, examples <80, lookup <100, errors <150, general <200 lines).

### 6. ORGANIZE — restructure context by concern rather than function

LOAD `references/engine/operations/organize.md` for the 8-stage workflow (scan → categorize → resolve conflicts → preview → backup → move → update → report). Always show a preview and get approval before moving files — see the approval-gate rule below.

### 7. CLEANUP — remove stale/temporary files

No dedicated reference file. Scope: `.tmp/` (session artifacts), `.tmp/external-context/` entries older than 7 days, orphaned `*.deprecated.md` beyond a reasonable retention window. **Never delete without showing what will be removed first** (see Critical Rules).

### 8. PROCESS — guided end-to-end workflow for a complex context request

No dedicated reference file. Sequence the other 7 operations as needed: typically DISCOVER → (HARVEST or EXTRACT) → ORGANIZE → validate. Narrate each step and its result before moving to the next.

## Setting Up From Scratch

If `{context_root}` doesn't resolve to anything (see `references/context-root-discovery.md` step 4), this is a new install:

1. Ask whether the primary need is **software development** (→ scaffold `project-intelligence/` from `assets/project-intelligence/`, standard at `references/domains/software-development/project-intelligence.md`, coding standards at `references/domains/software-development/standards/`) or **Labbit configuration** (→ scaffold `customer-intelligence/` from `assets/customer-intelligence/`, standard at `references/domains/labbit-configuration/customer-intelligence.md`, JSONC/BPMN standards at `references/domains/labbit-configuration/standards/`). Both can coexist.
2. Copy the relevant `assets/*` template set into the resolved (or newly chosen) `{context_root}`.
3. Create a root `navigation.md` if one doesn't exist (use `references/engine/standards/templates.md` for the template).
4. Record the chosen root in `.oac.json` so future sessions skip re-detection.

The `add-context` prompt automates this end-to-end for the common cases.

## Critical Rules

1. **MVI compliance.** Every context file stays under its type's line limit (see `references/engine/standards/mvi.md`). Extract the core concept in 1-3 sentences, 3-5 key points, a minimal example, and a reference link — no more.
2. **Approval gate before deleting or archiving.** Always present a lettered choice (A/B/C/"all") before any HARVEST cleanup or CLEANUP operation removes/archives files. Never auto-delete.
3. **Function-based structure.** New context areas use `concepts/`, `examples/`, `guides/`, `lookup/`, `errors/` — not a flat pile, not the old topic-based layout.
4. **Lazy load.** Read the specific reference file an operation needs, not the whole `references/` tree, before executing that operation.
5. **project-intelligence and customer-intelligence are always local.** Never write business/customer domain content to a global context root — only the universal engine tier belongs there.
6. **Engine rules aren't duplicated per domain.** If a domain doc restates a size limit or versioning rule instead of referencing the engine, that's a defect — fix it by replacing the restatement with a link.

## Priority

Rules above are Tier 1 (always win). Core operation execution (sections 1-8) is Tier 2. Cross-referencing, validation, and navigation polish is Tier 3. If a Tier 2 convenience conflicts with a Tier 1 rule — e.g. "just delete the stale file" vs. the approval gate — Tier 1 wins every time.
