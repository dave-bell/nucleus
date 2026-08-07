<!-- Context: domains/labbit-configuration/customer-intelligence | Priority: high | Version: 1.0 | Updated: 2026-07-21 -->

# Customer Intelligence

> **What**: Living documentation that bridges a customer's business needs and their actual Labbit configuration (JSONC config + BPMN processes).
> **Why**: Quick engagement understanding and onboarding for consultants, support engineers, and agents working this account.
> **Where**: `{context_root}/customer-intelligence/` (dedicated folder, one per project — typically one active customer per implementation repo, or one subfolder per customer in a multi-tenant consulting repo)

This is the labbit-configuration domain's counterpart to the software-development domain's `project-intelligence.md`. Same shape, same engine rules (MVI, frontmatter, versioning — see `../../engine/overview.md`), different content: business/technical domain knowledge here becomes customer/configuration knowledge.

## Quick Reference

| What You Need | File | Description |
|---------------|------|-------------|
| Understand the "who" | `customer-profile.md` | Industry, scale, goals, stakeholders |
| Understand the "what's configured" | `configuration-domain.md` | Modules, config file locations, integrations |
| Find a specific process | `process-map.md` | BPMN process inventory and customization status |
| Know why something is set a certain way | `customization-log.md` | Change history with rationale |
| Current state | `living-notes.md` | Active issues, open questions, upcoming work |

## Why This Exists

Customer implementations fail when:
- The reason for a config override is lost (nobody remembers *why* the threshold is 8000 instead of 5000)
- Process customizations diverge from Labbit's standard template with no record of what changed or why
- Context lives only in the consultant's head (who rotates off the account)
- The next consultant re-discovers the same override pattern across 3 more customers instead of recognizing it should be a Labbit default

This ensures **customer intent and actual configuration stay traceable to each other**.

## Structure

```
{context_root}/
├── customer-intelligence/             # Customer-specific context
│   ├── navigation.md                  # Quick overview & routes
│   ├── customer-profile.md            # Who they are, goals, stakeholders
│   ├── configuration-domain.md        # Modules, config locations, integrations
│   ├── process-map.md                 # BPMN process inventory
│   ├── customization-log.md           # Config/process changes with rationale
│   └── living-notes.md                # Active issues, open questions
└── (this skill's bundled references)  # Engine + labbit-configuration standards (not copied locally)
```

## Onboarding Checklist

For a new consultant joining this account:

- [ ] Read `navigation.md` (this file's sibling in the customer folder)
- [ ] Read `customer-profile.md` to understand who the customer is and their goals
- [ ] Read `configuration-domain.md` to understand what's actually configured
- [ ] Skim `process-map.md` for the process inventory and what's customized
- [ ] Check `customization-log.md` for rationale behind any non-default values
- [ ] Review `living-notes.md` for current state and open items

## How to Keep This Alive

| Trigger | Action |
|---------|--------|
| Module enabled/disabled | Update `configuration-domain.md` |
| Config value overridden from default | Log in `customization-log.md` |
| BPMN process added/customized/retired | Update `process-map.md` |
| New issue or open question | Update `living-notes.md` |
| Customer goals or stakeholders change | Update `customer-profile.md` |

**Full Management Guide**: See `./customer-intelligence-management.md`

## Integration with Context System

- **Lazy Loading**: Load customer intelligence first when picking up work on this account
- **Layering**: Then load `standards/jsonc-config-patterns.md`, `standards/bpmn-modeling-patterns.md`, or `standards/customer-config-governance.md` as needed for the specific artifact you're touching
- **Reference**: See `../../engine/overview.md` for the shared engine, and `navigation.md` for this domain's overview

## Related Files

- **Management Guide**: `./customer-intelligence-management.md`
- **Domain Overview**: `./navigation.md`
- **Engine**: `../../engine/overview.md`
- **Parallel Domain**: `../software-development/project-intelligence.md` (for building Labbit itself)
