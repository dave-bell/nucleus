<!-- Context: engine/navigation | Priority: critical | Version: 1.1 | Updated: 2026-07-21 -->

# Engine

**Purpose**: The domain-agnostic context-system engine — standards, operations, and guides shared by every domain (`domains/software-development/`, `domains/labbit-configuration/`). This is not itself a domain; it's the foundation both domains sit on.

---

## Structure

```
references/engine/
├── navigation.md (this file)
├── overview.md            # Architecture overview — read this first
├── examples/
│   └── navigation.md
├── guides/
│   └── navigation.md
├── operations/
│   └── navigation.md
└── standards/
    └── navigation.md
```

---

## Quick Routes

| Task | Path |
|------|------|
| **Understand the engine's architecture** | `overview.md` |
| **Operations & procedures** | `operations/navigation.md` |
| **Implementation guides** | `guides/navigation.md` |
| **Standards & templates** | `standards/navigation.md` |
| **Examples** | `examples/navigation.md` |
| **Migrate global → local** | `operations/migrate.md` |

---

## By Type

**Examples** → Working examples of navigation files
**Guides** → Step-by-step guides for working with context
**Operations** → How to operate and maintain the context system
**Standards** → Templates and standards for context files

---

## Used By Both Domains

Every domain applies these engine standards identically — MVI size limits, frontmatter format, function-based structure, codebase-reference sections, and the harvest/extract/organize/update/migrate/error operations. Domains never redefine these; they only add domain-specific *content* (what to capture) on top.

- **Software development domain** → `../domains/software-development/navigation.md`
- **Labbit-configuration domain** → `../domains/labbit-configuration/navigation.md`
