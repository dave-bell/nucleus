<!-- Context: core/migrate | Priority: medium | Version: 1.0 | Updated: 2026-02-15 -->

# Context Migrate Operation

**Purpose**: Copy context files from global (`{global_context_root}/`) to local (`{context_root}/`) so they're project-specific and git-committed.

**Last Updated**: 2026-02-06

---

## Core Problem

Users who installed this context system globally have project-intelligence files at `{global_context_root}/project-intelligence/`. These files are project-specific patterns but aren't committed to git or shared with the team.

**Solution**: Migrate project-intelligence from global → local, so patterns are version-controlled and team-shared.

---

## 4-Stage Workflow

<workflow id="migrate" enforce="@critical_rules">

### Stage 1: Detect Sources

Scan for context files in the global config directory:

```
Scanning global context...

Global location: {global_context_root}/

Found:
  project-intelligence/
    technical-domain.md (1.2 KB, Version: 1.3)
    navigation.md (800 bytes, Version: 1.0)
    business-domain.md (1.5 KB, Version: 1.1)

Local location: {context_root}/

Status: No local project-intelligence/ found
```

**If no global context found:**
```
No global context found at {global_context_root}/

Nothing to migrate. Use /add-context to create project intelligence.
```
→ Exit

**If no global project-intelligence found (but other global context exists):**
```
Global context found at {global_context_root}/ but no project-intelligence/ directory.

Only project-intelligence files are migrated (project-specific patterns).
Core standards stay in global (they're universal, not project-specific).

Nothing to migrate. Use /add-context to create project intelligence.
```
→ Exit

---

### Stage 2: Check for Conflicts

If local `{context_root}/project-intelligence/` already exists:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Conflict: Local project-intelligence already exists
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Global files:                              Local files:
  technical-domain.md                        technical-domain.md
    Version: 1.3, Updated: 2026-01-15         Version: 1.0, Updated: 2026-02-01
  navigation.md                              navigation.md
    Version: 1.0, Updated: 2026-01-10         Version: 1.0, Updated: 2026-02-01
  business-domain.md                         (not present locally)
    Version: 1.1, Updated: 2026-01-12

Options:
  1. Skip existing — only copy files that don't exist locally
     → Will copy: business-domain.md
     → Will skip: technical-domain.md, navigation.md (local kept)

  2. Overwrite all — replace local with global versions
     → Will overwrite: technical-domain.md, navigation.md
     → Will copy: business-domain.md
     → Local backup created first

  3. Cancel

Choose [1/2/3]: _
```

**If user chooses 2 (Overwrite), show content diff first:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Diff: technical-domain.md
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Local (current):                    Global (incoming):
  Version: 1.0                        Version: 1.3
  Tech Stack: Next.js 14              Tech Stack: Next.js 15  ← different
  API: basic validation                API: Zod validation     ← different
  Component: same                      Component: same
  Naming: same                         Naming: same

Show full diff? [y/n]: _

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Backup local files to .tmp/backup/migrate-{timestamp}/ before overwriting?
[y/n] (default: y): _
```

If no conflicts → proceed directly to Stage 3.

---

### Stage 3: Approval & Copy

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Migration Plan
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Will copy from: {global_context_root}/project-intelligence/
Will copy to:   {context_root}/project-intelligence/

Files to copy:
  ✓ technical-domain.md (1.2 KB)
  ✓ navigation.md (800 bytes)
  ✓ business-domain.md (1.5 KB)

After migration:
  → Local files committed to git = team gets your patterns
  → Agents load local (overrides global)
  → Global files remain as fallback for other projects

Proceed? [y/n]: _
```

**Actions on approval:**
1. Create `{context_root}/project-intelligence/` if it doesn't exist
2. Copy each file from global → local
3. Validate copied files (frontmatter, MVI compliance)

---

### Stage 4: Cleanup & Confirmation

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Migration Complete
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Copied 3 files to {context_root}/project-intelligence/

  ✓ technical-domain.md
  ✓ navigation.md
  ✓ business-domain.md

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Clean up global project-intelligence?

The global files are no longer needed for THIS project (local takes priority).
Keeping them means they still apply as fallback to other projects.

  1. Keep global files (safe default)
  2. Remove global project-intelligence/ (only affects this user)

Choose [1/2] (default: 1): _
```

**If user chooses 2 (Remove):**
- Delete `{global_context_root}/project-intelligence/` only
- Do NOT touch `{global_context_root}/core/` or any other global context

</workflow>

---

## What Gets Migrated

| Migrated (project-specific) | NOT Migrated (universal) |
|---|---|
| `project-intelligence/` | `core/standards/` |
| `project-intelligence/technical-domain.md` | `core/engine/` |
| `project-intelligence/business-domain.md` | `core/workflows/` |
| `project-intelligence/navigation.md` | `core/guides/` |
| `project-intelligence/decisions-log.md` | Any other `core/` files |
| `project-intelligence/living-notes.md` | |

**Rationale**: Project intelligence is project-specific (YOUR tech stack, YOUR patterns). Core standards are universal (code quality, documentation standards) and should stay global.

---

## Error Handling

**Permission denied:**
```
Error: Cannot write to {context_root}/project-intelligence/
Check directory permissions and try again.
```

**Global path not found:**
```
No global context found at any candidate location.

Run the context-root-discovery protocol (see ../../context-root-discovery.md)
to confirm no global context exists, or set an explicit root in .oac.json:
  { "globalContextRoot": "/your/custom/path" }
/context migrate
```

---

## Related

- `/add-context` — Create new project intelligence (interactive wizard)
- `/context harvest` — Extract knowledge from summaries
- Context root resolution: `../../context-root-discovery.md`
