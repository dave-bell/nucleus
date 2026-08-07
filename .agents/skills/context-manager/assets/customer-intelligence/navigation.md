<!-- Context: customer-intelligence/nav | Priority: high | Version: 1.0 | Updated: 2026-07-21 -->

# Customer Intelligence

> Start here for quick understanding of a specific customer's solution configuration. Parallels `project-intelligence/` but for a configured customer engagement rather than the product itself.

## Structure

```
{context_root}/customer-intelligence/
├── navigation.md              # This file - quick overview
├── customer-profile.md        # Who the customer is, industry, scale, goals
├── configuration-domain.md    # Modules enabled, config file locations, tech footprint
├── process-map.md             # BPMN process inventory for this customer
├── customization-log.md       # Customer-specific config/process changes with rationale
└── living-notes.md            # Active issues, open questions, upcoming work
```

## Quick Routes

| What You Need | File | Description |
|---------------|------|-------------|
| Understand the customer | `customer-profile.md` | Industry, scale, goals, stakeholders |
| Understand what's configured | `configuration-domain.md` | Modules, config locations, integrations |
| Find a specific process | `process-map.md` | BPMN process inventory and status |
| Know why something is set a certain way | `customization-log.md` | Change history with rationale |
| Current state | `living-notes.md` | Open issues and upcoming work |

## Usage

**New Consultant on This Account**:
1. Start with `navigation.md` (this file)
2. Read `customer-profile.md` then `configuration-domain.md`
3. Skim `customization-log.md` for anything unusual
4. Check `living-notes.md` for what's currently in flight

## Integration

This folder is maintained per the **context-manager** skill's `references/domains/labbit-configuration/customer-intelligence-management.md` guide, following the standard defined in `customer-intelligence.md` in that same domain — see also `standards/jsonc-config-patterns.md`, `standards/bpmn-modeling-patterns.md`, and `standards/customer-config-governance.md` in that skill's bundled references.

## Maintenance

- Update `configuration-domain.md` when modules are enabled/disabled
- Log every customer-specific override in `customization-log.md`
- Review `living-notes.md` at the start of each engagement session
- Keep `process-map.md` in sync with actual `.bpmn` files — don't let it drift

## Related Files

- `../project-intelligence/` — the parallel domain for product development work
