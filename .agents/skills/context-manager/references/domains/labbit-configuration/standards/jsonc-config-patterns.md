<!-- Context: domains/labbit-configuration/standards/jsonc | Priority: critical | Version: 1.0 | Updated: 2026-07-21 -->

# JSONC Configuration Patterns

**Concept**: Customer configuration for **Labbit** is authored as **JSONC** (JSON with Comments) — plain JSON semantics, plus `//` and `/* */` comments for rationale that must survive in the file itself, not just in a separate doc.

---

## Key Points

- **Comment the "why", not the "what".** `"maxRetries": 5, // customer requested longer backoff due to legacy gateway timeouts` — the value is self-evident; the reason isn't.
- **One customer, one config root.** Never merge two customers' overrides into a single file. Each customer gets its own config tree; shared defaults live in a base/template file the customer file extends or overrides.
- **Schema-validate before hand-editing prose.** If a JSON Schema exists for the config shape, validate against it first — most "config bugs" are typos the schema would have caught immediately.
- **Never delete a key to disable a feature.** Set it to `false`/`null` explicitly with a comment. A missing key is ambiguous (not-set vs deliberately-removed); an explicit `false` is not.
- **Version every customer config file** with a header comment: `// config-version: 1.3 | updated: 2026-07-21 | by: <consultant>`.

---

## Minimal Example

```jsonc
// config-version: 1.2 | updated: 2026-07-21 | by: j.smith
{
  "customerId": "acme-corp",
  "modules": {
    "invoicing": true,
    "approvals": {
      "enabled": true,
      "threshold": 5000, // Acme's finance team requires approval above $5k (default is $10k)
    },
    "legacyExport": false, // disabled 2026-06-01, replaced by API integration — see decisions-log
  },
}
```

---

## What to Avoid

- ❌ Config files with no comments explaining customer-specific deviations from the default.
- ❌ Copy-pasting an entire base config into the customer file instead of overriding only what differs.
- ❌ Silent trailing commas or comments in files that get consumed by a strict JSON parser downstream — confirm the loader supports JSONC before relying on comments surviving into runtime.

---

## Reference

See `customer-config-governance.md` for how changes to these files are tracked and rolled out across customers.

## 📂 Codebase References

**Note**: Actual Labbit config file locations are deployment-specific. Record them in the consumer project's `{context_root}/customer-intelligence/configuration-domain.md`.
