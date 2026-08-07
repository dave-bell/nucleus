<!-- Context: domains/labbit-configuration/standards/governance | Priority: high | Version: 1.0 | Updated: 2026-07-21 -->

# Customer Config Governance

**Concept**: Rules for changing customer-specific Labbit JSONC config and BPMN process files safely, and for knowing when a customer-specific fix should become a Labbit-wide default instead.

---

## Key Points

- **Every change to a live customer's config/process needs a logged reason.** Record it in that customer's `{context_root}/customer-intelligence/customization-log.md` (mirrors the software-development domain's `decisions-log.md` pattern) — what changed, why, who requested it, date.
- **Three-strikes rule for promoting customer deviations to Labbit defaults.** If the same override shows up in 3+ customer configs, propose adding it to Labbit's base template/config schema instead of repeating it per-customer. Flag this in `living-notes.md` when you notice the pattern.
- **Never test config changes directly against a live customer.** Changes get validated against a schema and, where possible, a staging/sandbox copy before touching the customer's production config or process files.
- **Breaking changes to the base template require a migration note per affected customer.** If a shared default or process template changes in a way that affects existing customer overrides, list every customer whose config references the changed key/task ID before shipping the change.
- **Config and process changes ship together when coupled.** If a BPMN gateway condition depends on a JSONC threshold value, review and version both files as one change, not two independent edits.

---

## Minimal Example: Customization Log Entry

```markdown
## 2026-07-21 — Raised approval threshold for Acme Corp

**Changed**: `modules.approvals.threshold` 5000 → 8000
**Requested by**: Acme finance lead (email 2026-07-18)
**Reason**: Acme's new AP process handles more invoices per month; $5k threshold was
generating approval-queue backlog.
**Files**: `config/customers/acme-corp/config.jsonc`
**Related process**: No BPMN change — threshold read at runtime by `Process_ApproveInvoice`.
```

---

## What to Avoid

- ❌ Silent overrides with no log entry — the next consultant on this account has no idea why a value differs from default.
- ❌ Copy-pasting a fix across customer configs without checking whether it should be a base-template change instead.
- ❌ Deploying a process/config change to production without recording the rollback value.

---

## Reference

See `jsonc-config-patterns.md` and `bpmn-modeling-patterns.md` for the artifacts this governs, and the consumer project's `{context_root}/customer-intelligence/customization-log.md` for the live log.
