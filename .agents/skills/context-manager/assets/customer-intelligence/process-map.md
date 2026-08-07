<!-- Context: customer-intelligence/process-map | Priority: high | Version: 1.0 | Updated: 2026-07-21 -->

# Process Map

> Inventory of BPMN processes active for this customer. Keep in sync with the actual `.bpmn` files — this is a map, not the source of truth.

## Quick Reference

- **Purpose**: Know which processes exist, where, and whether they're standard or customized
- **Update When**: A process is added, removed, or its customization status changes
- **Audience**: Consultants, support engineers

## Process Inventory

| Process ID | Name | File | Status | Customized? |
|------------|------|------|--------|--------------|
| `Process_ApproveInvoice` | Approve Invoice | `processes/approve-invoice.bpmn` | Live | Yes — threshold override |
| `Process_OnboardVendor` | Onboard Vendor | `processes/onboard-vendor.bpmn` | Live | No — standard template |
| `[Process_Name]` | [Name] | `[path]` | [Live/Draft/Deprecated] | [Yes/No — summary] |

## Customizations Summary

For each customized process, one line pointing to the full rationale:

- `Process_ApproveInvoice`: threshold raised to 8000 — see `customization-log.md` (2026-07-21)

## Deprecated/Retired Processes

| Process ID | Retired Date | Replaced By | Why |
|------------|---------------|-------------|-----|
| [Old process] | [Date] | [New process] | [Reason] |

## Onboarding Checklist

- [ ] Know all active processes for this customer
- [ ] Know which are customized vs standard template
- [ ] Know where `.bpmn` files live in the repo/config store
- [ ] Understand any retired processes and why

## Related Files

- `configuration-domain.md` - Module/config context for these processes
- `customization-log.md` - Full rationale for each customization
- The context-manager skill's `references/domains/labbit-configuration/standards/bpmn-modeling-patterns.md` reference
