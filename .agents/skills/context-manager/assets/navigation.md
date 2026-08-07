<!-- Context: core/navigation | Priority: critical | Version: 1.0 | Updated: {date} -->

# Context Root Navigation

> Entry point for the context system. Route to the right domain before reading anything else.

## Structure

```
{context_root}/
├── navigation.md              # This file - start here
└── {project-intelligence and/or customer-intelligence}/
```

## Quick Routes

| Task | Path |
|------|------|
| **Building/extending the product (software dev)** | `project-intelligence/navigation.md` |
| **Configuring a customer solution (labbit-configuration)** | `customer-intelligence/navigation.md` |

*(Omit whichever domain row doesn't apply yet; add it later if `/add-context` is run again with the other mode.)*

## By Domain

**project-intelligence** → business/technical context for building the product itself.
**customer-intelligence** → customer profile, config, and process-map context for a named implementation.

## Usage

**New Team Member / Agent**:
1. Start here to see which domain(s) this project uses.
2. Follow the relevant domain's `navigation.md` for the full file set.

## Maintenance

- Update this file whenever a domain folder is added or removed (handled automatically by the `add-context` prompt via `context-organizer`).
- Never remove a domain's row just because it hasn't been touched recently — only remove it if the domain folder itself is deleted.

## Related Files

- **project-intelligence** → `project-intelligence/navigation.md` (if present)
- **customer-intelligence** → `customer-intelligence/navigation.md` (if present)
