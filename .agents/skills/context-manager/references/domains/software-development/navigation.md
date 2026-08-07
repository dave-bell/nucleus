<!-- Context: domains/software-development/navigation | Priority: high | Version: 1.0 | Updated: 2026-07-22 -->

# Software Development Domain

**Purpose**: Standards for building Labbit itself — the product-development use case for engineers. Artifacts here are source code, tests, and documentation, not customer configuration.

This domain is the sibling of `../labbit-configuration/` (which covers configuring Labbit for a customer). Both sit on the shared engine (`../../engine/`) — see that engine's `overview.md` for the MVI/frontmatter/structure rules both domains follow identically. Use this domain when the task is "build/change a Labbit feature", not "configure Labbit for customer X".

---

## Structure

```
domains/software-development/
├── navigation.md (this file)
├── project-intelligence.md               # Standard: what/why/where
├── project-intelligence-management.md    # Management guide: engine mechanics + domain deltas
└── standards/
    ├── navigation.md          # Index of the 7 coding standards below
    ├── code-quality.md
    ├── test-coverage.md
    ├── documentation.md
    ├── security-patterns.md
    ├── code-analysis.md
    ├── clean-code.md
    └── api-design.md
```

Per-project living documentation lives in the consumer's project at `{context_root}/project-intelligence/` — populated from this skill's `assets/project-intelligence/` template set, maintained per `project-intelligence-management.md`.

---

## Quick Routes

| Task | Path |
|------|------|
| Understand this domain's standard (what/why/where) | `project-intelligence.md` |
| Add/update/deprecate a project-intelligence file | `project-intelligence-management.md` |
| Write or review code | `standards/code-quality.md` |
| Write tests | `standards/test-coverage.md` |
| Write docs | `standards/documentation.md` |
| Security review | `standards/security-patterns.md` |
| Design an API | `standards/api-design.md` |
| Full standards index | `standards/navigation.md` |

---

## When to Use This Domain vs `../labbit-configuration/`

| Situation | Domain |
|---|---|
| Building/extending Labbit itself (code) | This domain |
| Configuring Labbit for a named customer (JSONC + BPMN) | `../labbit-configuration/` + `{context_root}/customer-intelligence/` |
| A change touches both (e.g. a new Labbit config option needs product code) | Load both — start here, cross-reference `../labbit-configuration/standards/customer-config-governance.md` for how the change propagates to existing Labbit customers |

---

## Related Context

- `project-intelligence.md` — this domain's standard
- `project-intelligence-management.md` — this domain's management guide
- `standards/navigation.md` — coding standards index
- `../labbit-configuration/navigation.md` — parallel domain, customer-configuration standard
- `../../engine/overview.md` — the shared engine both domains use
