<!-- Context: domains/labbit-configuration/customer-intelligence-management | Priority: high | Version: 1.0 | Updated: 2026-07-21 -->

# Customer Intelligence Management

> **What**: How to manage customer intelligence files and folders.
> **When**: Use this guide when adding, updating, or removing customer intelligence files.
> **Related**: See `customer-intelligence.md` for what and why.

This guide only covers what **differs** from the software-development domain's equivalent. For the generic mechanics — file size limits, frontmatter format, versioning rules, deprecation process, subfolder rules — see `../../engine/standards/mvi.md`, `../../engine/standards/frontmatter.md`, and `../software-development/project-intelligence-management.md` (the mechanics sections there are engine rules, not software-specific, and apply here unchanged).

## Quick Reference

| Action | Do This |
|--------|---------|
| Update existing file | Edit + bump frontmatter version (see engine versioning rules) |
| Add new file | Create `.md` + add to `navigation.md` (engine rule — unchanged) |
| Add subfolder | e.g. one subfolder per customer in a multi-tenant repo — create folder + `navigation.md` + update parent nav |
| Remove file | Rename `.deprecated.md` + archive, don't delete (engine rule — unchanged) |
| Log a config/process change | Add an entry to `customization-log.md` **first**, then update the file the change affects |

---

## What's Different From `project-intelligence-management.md`

### 1. Update Triggers (domain-specific)

| Trigger | Action |
|---------|--------|
| Module enabled/disabled | Update `configuration-domain.md` |
| Config value overridden from default | **Log in `customization-log.md` first**, then update `configuration-domain.md` |
| BPMN process added, customized, or retired | Update `process-map.md`; if customized, cross-reference the customization-log entry |
| Customer goals, industry, or stakeholders change | Update `customer-profile.md` |
| New issue or open question | Update `living-notes.md` |

Unlike the software-dev domain (where `decisions-log.md` is updated after the fact), **every config/process change here must be logged in `customization-log.md` before or alongside the change** — see `../standards/customer-config-governance.md`'s approval-gate rule. This is a hard requirement, not a convention.

### 2. Multi-Customer Subfolders

If this project serves multiple customers (a consulting repo, not a single-customer implementation), use one subfolder per customer:

```
customer-intelligence/
├── navigation.md                    # Root nav — lists all customer subfolders
├── acme-corp/
│   ├── navigation.md
│   ├── customer-profile.md
│   └── ... (same 6-file structure)
└── globex-inc/
    ├── navigation.md
    └── ...
```

Same engine rule applies: every subfolder needs its own `navigation.md`. Don't nest deeper than customer-name → files (no sub-subfolders per customer unless a single customer's config genuinely spans 5+ files per category).

### 3. The Three-Strikes Promotion Rule

Unique to this domain: when reviewing or updating `customization-log.md`, check whether the same override now appears across 3+ customers (tracked in the log's "Candidates for Base-Template Promotion" table). If so, this is a signal to propose a Labbit-default change, not just log another customer override. See `../standards/customer-config-governance.md`.

### 4. Governance (domain-specific ownership)

| Area | Owner | Responsibility |
|------|-------|----------------|
| Customer profile | Account consultant | Keep goals/stakeholders current |
| Configuration domain | Implementation consultant | Keep config/module state accurate |
| Process map | Implementation consultant | Keep `.bpmn` inventory in sync with actual files |
| Customization log | Implementation consultant | Log every change before/alongside making it |
| Living notes | Whoever is actively engaged | Keep open items current |

**Review Cadence**: Same as engine default (quick review per change, full review quarterly, archive review semi-annually) — see `project-intelligence-management.md`'s table if a different cadence isn't specified for this account.

---

## Checklist

### Add New Customer (fresh engagement)
- [ ] Create `customer-intelligence/` folder (or a per-customer subfolder if multi-tenant)
- [ ] Copy the template set from this skill's `assets/customer-intelligence/`
- [ ] Fill `customer-profile.md` first — everything else builds on it
- [ ] Add to parent `navigation.md` if using multi-customer subfolders

### Log a Config/Process Change (routine)
- [ ] Add entry to `customization-log.md` with reason, requester, files touched
- [ ] Update the affected file (`configuration-domain.md` or `process-map.md`)
- [ ] Check the three-strikes table — does this override now appear 3+ times across customers?

### Deprecate/Retire (engagement ends or process retired)
- [ ] Rename with `.deprecated.md` (engine rule — unchanged)
- [ ] Add retirement entry to `process-map.md`'s "Deprecated/Retired Processes" table if process-related
- [ ] Never delete `customization-log.md` — it's the audit trail

---

## Related Files

- **Standard**: `customer-intelligence.md`
- **Domain Overview**: `navigation.md`
- **Engine mechanics (versioning, deprecation, size limits)**: `../software-development/project-intelligence-management.md`, `../../engine/standards/mvi.md`, `../../engine/standards/frontmatter.md`
- **Governance standard**: `../standards/customer-config-governance.md`
