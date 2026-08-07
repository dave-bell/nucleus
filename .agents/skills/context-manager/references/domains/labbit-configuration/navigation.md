<!-- Context: domains/labbit-configuration/navigation | Priority: high | Version: 1.2 | Updated: 2026-07-21 -->

# Labbit Configuration Domain

**Purpose**: Standards for configuring **Labbit** for a specific customer — the enterprise-solution-implementation use case for consultants. Artifacts here are **JSONC configuration documents** and **BPMN process files**, not Labbit's own application source code.

This domain is the sibling of `../software-development/` (which covers building Labbit itself). Both sit on the shared engine (`../../engine/`) — see that engine's `overview.md` for the MVI/frontmatter/structure rules both domains follow identically. Use this domain when the task is "configure Labbit for customer X", not "add a feature to Labbit".

---

## Structure

```
domains/labbit-configuration/
├── navigation.md (this file)
├── customer-intelligence.md               # Standard: what/why/where (mirrors project-intelligence.md)
├── customer-intelligence-management.md    # Management guide: engine mechanics + domain deltas
└── standards/
    ├── jsonc-config-patterns.md      # How to write/validate Labbit's JSONC config docs
    ├── bpmn-modeling-patterns.md     # How to model/name Labbit BPMN processes
    └── customer-config-governance.md # Versioning & change control for customer config
```

Per-customer living documentation lives in the consumer's project at `{context_root}/customer-intelligence/` — populated from this skill's `assets/customer-intelligence/` template set, maintained per `customer-intelligence-management.md`. The folder is still called `customer-intelligence/` (not `labbit-intelligence/`) because it tracks the *customer's* implementation; this domain is the ruleset that governs how you populate and maintain it.

---

## Quick Routes

| Task | Path |
|------|------|
| Understand this domain's standard (what/why/where) | `customer-intelligence.md` |
| Add/update/deprecate a customer-intelligence file | `customer-intelligence-management.md` |
| Write/edit a Labbit JSONC config doc | `standards/jsonc-config-patterns.md` |
| Model or edit a Labbit BPMN process | `standards/bpmn-modeling-patterns.md` |
| Track customer-specific deviations from Labbit defaults | `standards/customer-config-governance.md` |
| Understand a specific customer's Labbit setup | `{context_root}/customer-intelligence/navigation.md` |

---

## When to Use This Domain vs `../software-development/`

| Situation | Domain |
|---|---|
| Building/extending Labbit itself (code) | `../software-development/` |
| Configuring Labbit for a named customer (JSONC + BPMN) | This domain + `{context_root}/customer-intelligence/` |
| A change touches both (e.g. a new Labbit config option needs product code) | Load both — start with `../software-development/project-intelligence.md`, cross-reference `standards/customer-config-governance.md` for how the change propagates to existing Labbit customers |

---

## Related Context

- `customer-intelligence.md` — this domain's standard
- `customer-intelligence-management.md` — this domain's management guide
- `../software-development/project-intelligence.md` — parallel domain, Labbit-the-product standard
- `../../engine/overview.md` — the shared engine both domains use
