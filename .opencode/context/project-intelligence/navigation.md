<!-- Context: project-intelligence/nav | Priority: high | Version: 1.0 | Updated: 2026-08-07 -->

# Project Intelligence

> Start here for quick project understanding. These files bridge business and technical domains.

## Structure

```
.opencode/context/project-intelligence/
├── navigation.md              # This file - quick overview
├── business-domain.md         # Business context and problem statement
├── technical-domain.md        # Stack, architecture, technical decisions
├── business-tech-bridge.md    # Requirement → codebase traceability map
├── decisions-log.md           # Major decisions with rationale
└── living-notes.md            # Active issues, debt, open questions
```

## Quick Routes

| What You Need | File | Description |
|---------------|------|-------------|
| Understand the "why" | `business-domain.md` | Problem, users, value proposition |
| Understand the "how" | `technical-domain.md` | Stack, architecture, integrations |
| Find the requirement for a feature | `business-tech-bridge.md` | Action ID → LiveView module → test |
| Know the context | `decisions-log.md` | Why decisions were made |
| Current state | `living-notes.md` | Active issues and open questions |
| All of the above | Read all files in order | Full project intelligence |

## Requirements Live Elsewhere

The 114 numbered requirements ("actions") for Nucleus are held in the wiki submodule at
`docs/requirements/`, **not** in these files. `business-tech-bridge.md` is the index into
them. Do not copy requirement text into this folder — it will drift.

## Usage

**New Team Member / Agent**:
1. Start with `navigation.md` (this file)
2. Read all files in order for complete understanding
3. Follow onboarding checklist in each file

**Quick Reference**:
- Business focus → `business-domain.md`
- Technical focus → `technical-domain.md`
- Decision context → `decisions-log.md`

## Integration

This folder is maintained using the standard defined by the **context-manager** skill's
`references/domains/software-development/project-intelligence.md` reference.

## Maintenance

Keep this folder current:
- Update when business direction changes
- Document decisions as they're made
- Review `living-notes.md` regularly
- Archive resolved items from `decisions-log.md`
- Re-check `business-tech-bridge.md` after `git submodule update --remote docs/requirements`

**Management Guide**: See the context-manager skill's
`references/domains/software-development/project-intelligence-management.md` for lifecycle
management, version tracking, quality checklists, and governance.
