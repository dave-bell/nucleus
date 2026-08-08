<!-- Context: core/navigation | Priority: critical | Version: 1.2 | Updated: 2026-08-07 -->

# Context Root Navigation

> Entry point for the context system. Route to the right domain before reading anything else.

## Structure

```
.opencode/context/
├── navigation.md              # This file - start here
├── workflows/                 # Process workflows (tickets, decisions, delivery)
└── project-intelligence/      # Business + technical context for building Nucleus
```

## Quick Routes

| Task | Path |
|------|------|
| **Answering a question or decision on a ticket / issue** (`EN-n`, `SEC-Sn`, `needs-decision`) | `workflows/navigation.md` |
| **Working a ticket: GitHub Issues, labels, comments, `gh`** | `workflows/navigation.md` |
| **Implementing a ticket: branches, worktrees, commits, pull requests** | `workflows/navigation.md` |
| **Building/extending the product (software dev)** | `project-intelligence/navigation.md` |

*(No `customer-intelligence/` domain exists in this project yet. Run `/add-context` with `mode=config` to add one.)*

## By Domain

**workflows** → process conventions for tickets, decisions, and issue hygiene.

**project-intelligence** → business/technical context for building the product itself.

## External Requirements Source

Nucleus requirements are **not** stored in this context system. They live in the project
wiki, checked out as a pinned git submodule at `docs/requirements/`. Context files here
map those requirements onto this codebase — they never restate them.

- Requirements checkout → `docs/requirements/` (submodule of `nucleus.wiki`)
- Traceability map + tagging convention → `project-intelligence/business-tech-bridge.md`

Refresh with `git submodule update --remote docs/requirements` when the wiki changes.

## Usage

**New Team Member / Agent**:
1. Start here to see which domain(s) this project uses.
2. Follow the relevant domain's `navigation.md` for the full file set.
3. For *what* to build, read `docs/requirements/`. For *how* it maps to this codebase,
   read `project-intelligence/business-tech-bridge.md`.

## Maintenance

- Update this file whenever a domain folder is added or removed.
- Never remove a domain's row just because it hasn't been touched recently — only remove it
  if the domain folder itself is deleted.

## Related Files

- **workflows** → `workflows/navigation.md`
- **project-intelligence** → `project-intelligence/navigation.md`
- **Code standards** → `AGENTS.md` at the project root (authoritative for Elixir/Phoenix/LiveView)
