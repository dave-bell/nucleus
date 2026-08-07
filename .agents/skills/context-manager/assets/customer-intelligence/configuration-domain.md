<!-- Context: customer-intelligence/config-domain | Priority: high | Version: 1.0 | Updated: 2026-07-21 -->

# Configuration Domain

> Document what's actually configured for this customer: modules, config file locations, integrations.

## Quick Reference

- **Purpose**: Understand this customer's technical configuration footprint
- **Update When**: Modules change, config files move, new integration added
- **Audience**: Consultants, support engineers, technical stakeholders

## Enabled Modules

| Module | Enabled | Notes |
|--------|---------|-------|
| [e.g., Invoicing] | Yes | [Any customization] |
| [e.g., Approvals] | Yes | [Threshold overridden — see customization-log.md] |
| [e.g., Legacy Export] | No | [Disabled 2026-06-01, replaced by API] |

## Config File Locations

| File | Purpose | Format |
|------|---------|--------|
| `config/customers/[customer]/config.jsonc` | Primary customer config | JSONC — see `standards/jsonc-config-patterns.md` |
| `config/customers/[customer]/overrides/*.jsonc` | Module-specific overrides | JSONC |

## Process Footprint

[Summary of which BPMN processes are active for this customer. Full inventory in `process-map.md`.]

## Integration Points

| System | Purpose | Protocol | Direction |
|--------|---------|----------|-----------|
| [Customer's ERP] | [What it exchanges] | [REST/SFTP/etc] | [Inbound/Outbound] |
| [Auth provider] | [SSO] | [SAML/OIDC] | [Inbound] |

## Technical Constraints

| Constraint | Origin | Impact |
|------------|--------|--------|
| [e.g., On-prem only] | [Customer policy] | [No cloud-hosted config store] |

## Onboarding Checklist

- [ ] Know which modules are enabled/disabled and why
- [ ] Know where this customer's config files live
- [ ] Understand active integrations
- [ ] Know technical constraints unique to this customer

## Related Files

- `customer-profile.md` - Why this configuration exists
- `process-map.md` - BPMN process inventory
- `customization-log.md` - Full change history with rationale
