<!-- Context: customer-intelligence/profile | Priority: high | Version: 1.0 | Updated: 2026-07-21 -->

# Customer Profile

> Document who this customer is and what they're trying to achieve. This is the "why" behind their configuration.

## Quick Reference

- **Purpose**: Understand the customer's business context before touching their config
- **Update When**: New engagement phase, scope change, new stakeholder
- **Audience**: Consultants, support, account team

## Customer Identity

| Field | Value |
|-------|-------|
| Customer Name | [Name] |
| Industry | [e.g., Manufacturing, Healthcare, Logistics] |
| Scale | [Employees / transaction volume / sites] |
| Engagement Start | [Date] |
| Current Phase | [Discovery / Implementation / Live / Support] |

## Goals

[What is this customer trying to achieve with this solution? What problem does it solve for them?]

## Stakeholders

| Name/Role | Responsibility | Contact Preference |
|-----------|-----------------|---------------------|
| [e.g., Finance Lead] | [Approves config changes to invoicing] | [Email/Slack] |
| [e.g., IT Admin] | [Owns integration credentials] | [Email/Slack] |

## Success Metrics

[How does the customer measure whether this implementation is working? e.g., "invoice approval time under 2 days"]

## Constraints

| Constraint | Origin | Impact |
|------------|--------|--------|
| [e.g., Legacy ERP integration] | [Existing system] | [Limits which modules can be enabled] |
| [e.g., Regulatory requirement] | [Industry compliance] | [Must be reflected in process/config] |

## Onboarding Checklist

- [ ] Know the customer's industry and scale
- [ ] Understand their primary goals for this implementation
- [ ] Know key stakeholders and how to reach them
- [ ] Understand constraints that shape their configuration

## Related Files

- `configuration-domain.md` - How goals translate into actual config
- `customization-log.md` - Decisions made to serve this customer's needs
