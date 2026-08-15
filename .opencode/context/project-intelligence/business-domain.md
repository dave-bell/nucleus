<!-- Context: project-intelligence/business | Priority: high | Version: 1.1 | Updated: 2026-08-14 -->

# Business Domain

> Document the business context, problems solved, and value created.

## Quick Reference

- **Purpose**: Understand why this project exists
- **Update When**: Business direction changes, new features shipped, pivot
- **Audience**: Developers needing context, stakeholders, product team

## Project Identity

```
Project Name: Nucleus
Tagline: Control plane for tenant configuration across Nomad, AWS SSM, and Cognito
Problem Statement: Ops/Support teams need to read and change tenant configuration spread
  across three unrelated backing systems, but granting them direct credentials or console
  access to each is unsafe, unauditable, and impractical to administer.
Solution: A single per-tenant web application that reads and updates that configuration on
  the user's behalf, forwarding the user's own identity, and recording an audit trail.
```

## Requirements Authority

**The wiki is binding.** All user-facing behaviour is specified as numbered *actions* in the
wiki, checked out at `docs/requirements/`. Every action has a stable ID (e.g. `SEC-A03`)
that is never reused or renumbered, so it can be cited from a test name or bug report.

113 actions across 10 pages. See `business-tech-bridge.md` for the ID → codebase map.

**Scope note**: the wiki's *architecture* sections (its diagram, its `API:` contract lines,
and `ADR-0001`–`ADR-0007`) describe an earlier prototype built with a Python API and a React
frontend. This project is a fresh start and does not inherit that architecture. The
requirements bind; the architecture does not.

## Target Users

| User Segment | Who They Are | What They Need | Pain Points |
|--------------|--------------|----------------|-------------|
| Ops/Support engineer (primary) | Member of a designated Cognito group for one tenant | Read and change tenant config across Nomad Variables, SSM Parameter Store, and Cognito M2M clients | Would otherwise need credentials and console access to three separate systems, per tenant |
| *(no secondary segment)* | Application teams are explicitly **not** users — self-service config is out of scope | — | — |

Internal tool, used on workstations. There is no mobile or tablet experience.

## Value Proposition

**For Users**:
- One place to read and change tenant configuration, instead of three consoles
- No direct credentials needed for Nomad, AWS, or Cognito
- Read-only operational visibility into deployed jobs and environments

**For Business**:
- Removes standing production credentials from Ops/Support workstations
- Produces an audit trail for configuration change and secret access

## Core Model

These five principles are binding constraints. Product/safety constraints are listed under
**Business Constraints** below; the three architectural ones are recorded in
`technical-domain.md` under *Technical Constraints*.

| Principle | Meaning | Recorded in |
|-----------|---------|-------------|
| **One instance per tenant** | Each deployment is scoped to exactly one tenant namespace. No tenant switcher exists. | This file |
| **Read + update only** | Except for M2M client creation and secret creation, Nucleus never creates or deletes configuration. Irreversible operations are out of scope. | This file |
| **Stateless** | No database of its own. Every displayed value is read live from a backing system. | `technical-domain.md` |
| **Pluggable backends** | Backing systems are reached through swappable interfaces. | `technical-domain.md` |
| **Token passthrough** | The signed-in user's own access token is forwarded, so their permissions apply end-to-end. | `technical-domain.md` |

## Success Metrics

| Metric | Definition | Target | Current |
|--------|------------|--------|---------|
| [Metric 1] | [What it measures] | [Goal] | [Actual] |
| [Metric 2] | [What it measures] | [Goal] | [Actual] |

*Not yet defined.*

## Business Model (if applicable)

Not applicable — internal operational tooling, not a revenue-generating product.

## Key Stakeholders

| Role | Name | Responsibility | Contact |
|------|------|----------------|---------|
| [Product Owner] | [Name] | [What they own] | [Contact] |
| [Tech Lead] | [Name] | [What they own] | [Contact] |

*Not yet recorded.*

## Roadmap Context

**Current Focus**: Fresh-start implementation. Codebase is a generated Phoenix skeleton; no
feature work has begun.
**Next Milestone**: [Not yet defined]
**Long-term Vision**: [Not yet defined]

## Business Constraints

- **One deployment serves exactly one tenant** — a user only ever sees data for their
  tenant, and there is no tenant switcher to build or secure.
- **Read + update only** — no delete for Nomad Variables or Parameter Store secrets, and no
  update or delete for M2M clients. This is a deliberate safety boundary against
  irreversible operations, not a missing feature.
- **Access is group-gated** — only members of the tenant's designated Cognito group.
- **Desktop only** — no mobile or responsive layouts required.

## Glossary

| Term | Meaning |
|------|---------|
| **Tenant** | A customer instance, identified by a namespace (e.g. `qa-bb`). One deployment serves one tenant. |
| **Namespace** | The tenant's identifier. Prefixes Nomad jobs/variables and M2M client names. Not used for Parameter Store paths — see `CLUSTER_NAME`/`DEPLOYMENT_NAME` (`docs/adr/0007-secrets-store-adapter.md`). |
| **Environment** | A deployment stage within a tenant (e.g. `prod`, `staging`, `dev`). Defined by the tenant's backing API, not by Nucleus. |
| **M2M client** | A Cognito App Client using the `client_credentials` OAuth flow, for external systems calling tenant APIs without a human user. |
| **Data Export** | An optional tenant capability, configured via a dedicated Nomad job and matching Nomad Variables. |
| **Secret** | An encrypted key/value pair in AWS SSM Parameter Store, scoped to one environment. |

## Out of Scope

Deliberate non-goals, not gaps:

- Self-service configuration for application teams
- Create/delete for Nomad Variables; delete for Parameter Store secrets
- Update/delete for M2M clients
- Any persistent store of its own for audit history or metadata
- Mobile or responsive layouts

## Onboarding Checklist

- [ ] Understand the problem statement
- [ ] Know who the users are, and who is explicitly not a user
- [ ] Know the five core-model principles and where each is recorded
- [ ] Understand why read+update-only is a safety boundary
- [ ] Know that `docs/requirements/` is the binding requirements source
- [ ] Understand that the wiki's architecture sections do not bind this project

## Related Files

- `technical-domain.md` - How this business need is solved technically
- `business-tech-bridge.md` - Requirement ID → codebase mapping
- `decisions-log.md` - Business decisions with context
- `docs/requirements/Home.md` - Wiki entry point (submodule)
