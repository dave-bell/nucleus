<!-- Context: domains/software-development/standards/navigation | Priority: critical | Version: 1.0 | Updated: 2026-07-22 -->

# Software Development Standards

**Purpose**: Language-agnostic coding standards for building the product itself. Mirrors the labbit-configuration domain's `standards/` directory.

---

## Files

| File | Topic | Priority | Load When |
|------|-------|----------|-----------|
| `code-quality.md` | Modular, functional code principles | ⭐⭐⭐⭐⭐ | Writing or reviewing any code |
| `test-coverage.md` | Testing standards, AAA pattern, coverage goals | ⭐⭐⭐⭐⭐ | Writing tests |
| `documentation.md` | README, comments, API doc standards | ⭐⭐⭐⭐ | Writing docs |
| `security-patterns.md` | Error handling, validation, secrets, logging | ⭐⭐⭐⭐ | Security review, any code touching input/auth/secrets |
| `code-analysis.md` | Systematic analysis framework | ⭐⭐⭐ | Analyzing code, debugging, writing an analysis report |
| `clean-code.md` | Naming, function size, DRY, per-language notes | ⭐⭐⭐⭐ | Writing any code |
| `api-design.md` | REST/GraphQL design, versioning, auth patterns | ⭐⭐⭐⭐ | Designing or reviewing an API |

---

## Loading Strategy

**For code implementation**:
1. Load `code-quality.md` (critical)
2. Load `security-patterns.md` (high)

**For testing**:
1. Load `test-coverage.md` (critical)
2. Depends on: `code-quality.md`

**For documentation**:
1. Load `documentation.md` (critical)

**For code review**:
1. Load `code-quality.md` (critical)
2. Load `security-patterns.md` (high)
3. Load `test-coverage.md` (high)

**For API development**:
1. Load `api-design.md` (high)
2. Also load: `code-quality.md` (critical)

**For debugging/analysis**:
1. Load `code-analysis.md` (high)

---

## Relationship to the Engine

These are domain content (what to follow when writing code), not engine rules (how context files themselves are structured). The engine's own standards — MVI, frontmatter, structure — govern how these files are written; see `../../../engine/standards/navigation.md`. Don't confuse the two: a change to *coding* conventions belongs here; a change to *context-file* conventions belongs in the engine.

## Related

- **Domain Overview** → `../navigation.md`
- **Project Intelligence standard** → `../project-intelligence.md`
- **Engine standards** → `../../../engine/standards/navigation.md`
- **Labbit-configuration's standards (parallel domain)** → `../../labbit-configuration/standards/`
