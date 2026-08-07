<!-- Context: customer-intelligence/customization-log | Priority: high | Version: 1.0 | Updated: 2026-07-21 -->

# Customization Log

> Record every customer-specific config/process change with full rationale. This prevents "why is this set differently?" debates and supports the three-strikes-promote-to-default rule.

## Quick Reference

- **Purpose**: Document why this customer's config/processes deviate from standard defaults
- **Format**: Each change as a dated entry, most recent first
- **Status**: Active | Superseded | Reverted

## Entry Template

```markdown
## YYYY-MM-DD — [Short title]

**Changed**: [key/path] [old value] → [new value]
**Requested by**: [Who asked, and how (email/call/ticket)]
**Reason**: [Business reason for the change]
**Files**: [Which config/process files were touched]
**Related process**: [BPMN process ID if applicable, or "None"]
**Status**: Active
```

---

## YYYY-MM-DD — [Title]

**Changed**: [key] [old] → [new]
**Requested by**: [Who]
**Reason**: [Why]
**Files**: [Files touched]
**Related process**: [Process ID or None]
**Status**: Active

---

## Superseded/Reverted Changes

| Change | Date | Reverted/Superseded By | Why |
|--------|------|--------------------------|-----|
| [Old change] | [Date] | [New entry] | [Reason] |

## Candidates for Base-Template Promotion

Track overrides seen across 3+ customers here (per `standards/customer-config-governance.md`'s three-strikes rule):

| Override | Customers Seen | Promote to Default? |
|----------|------------------|----------------------|
| [e.g., threshold > 5000] | [Acme, Globex, Initech] | [Under review / Yes / No] |

## Onboarding Checklist

- [ ] Understand every active customization and its business reason
- [ ] Know which changes were reverted and why
- [ ] Check for override patterns that should become product defaults

## Related Files

- `configuration-domain.md` - Current state this log explains
- `process-map.md` - Processes affected by logged changes
- `living-notes.md` - Open questions that may become logged decisions
