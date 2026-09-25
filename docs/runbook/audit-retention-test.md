# Audit Retention Runbook

Operator-facing checklist for the `manual` half of `AUD-A06` (audit trail on a
distinct output stream from application logs, retained independently of
routine logging noise). The unit half — `:stderr` being a distinct device
from `Logger`'s by construction — is covered by an automated test
(`test/nucleus/audit/sink/device_test.exs`); this document covers what no test in
this repository can verify, because it depends on the deployment, not the
code.

This is a checklist to run against a real deployment, not a description of
Nucleus's internals. For the reasoning behind each item, see
`docs/adr/0004-audit-emission.md`'s "Operational dependency — external
retention is not optional" section (under "Consequences") — this document
translates that section into operator action and does not repeat its
reasoning.

## 1. Capture

`AUDIT_DEVICE` defaults to `:stderr`. This default is deliberate, not
incidental: application/diagnostic output goes to `:stdout` (`Logger`'s
default), so a container runtime or log shipper can route the two streams to
different destinations — one for routine logs, one for compliance-grade
audit records — with no change to the application.

**Action:** confirm the deployment's log pipeline captures `:stderr`
separately from `:stdout`, and routes it to the destination that satisfies
items 3 and 4 below. If `AUDIT_DEVICE` has been overridden to `:stdout`, the
two streams are merged and this separation is lost — confirm that override,
if present, is intentional.

## 2. `AUDIT_DEVICE` as a file path is a local-development convenience, not a production option

`AUDIT_DEVICE` also accepts a file path. That path is opened once at process
boot and the handle is held for the life of the process. External log
rotation (a tool renaming or truncating that file out from under the running
process) is not handled — writes after rotation are silently misdirected to
the renamed or now-nonexistent file, not the new one a rotation tool expects
to be written.

**Action:** do not point `AUDIT_DEVICE` at a file path in any environment
that claims compliance retention. Use the `:stderr` (or `:stdout`) default
and let the container runtime and its own log rotation handle the file
lifecycle instead. Treat a file-path `AUDIT_DEVICE` in a production
configuration as a misconfiguration to correct, not a variant to support.

## 3. Retention

Nucleus does not persist audit records anywhere — there is no local store to
retain them in (`docs/adr/0001-no-local-datastore.md`). Whatever captures
the stream in item 1 is entirely responsible for retaining it for the
compliance window the deployment claims: 1–7 years for SOC2 (CC7.2) / HIPAA
(164.312(b)), per the wiki's prior-art ADR-0003. Nucleus has no way to
enforce or verify that this retention is happening.

**Action:** confirm the log pipeline's retention configuration (e.g. the log
shipper's or object store's lifecycle policy) actually matches the
compliance window the deployment claims, not a shorter default.

## 4. Tamper-evidence

The capture destination should be append-only or otherwise tamper-evident —
a write-once log store, not a mutable file an operator (or an attacker with
operator access) can silently edit after the fact. This is a property of the
deployment's log pipeline; Nucleus has no mechanism to enforce or detect
tampering after a record leaves the process.

**Action:** confirm the capture destination is configured append-only /
write-once, and that write access to it is restricted separately from the
Nucleus deployment's own credentials — the audit trail should survive a
compromise of the application it's auditing.

## 5. Verification checklist

Run this after any change to `AUDIT_FORMAT`, `AUDIT_DEVICE`, or the log
pipeline configuration, and periodically as part of routine compliance
verification:

- [ ] `AUDIT_FORMAT` and `AUDIT_DEVICE` are set as intended for this
      environment (unset `AUDIT_FORMAT` defaults to `json`; unset
      `AUDIT_DEVICE` defaults to `:stderr`).
- [ ] The configured device (`:stderr` unless overridden) is captured by the
      deployment's log pipeline as a stream **distinct from `:stdout`** —
      confirm this by inspecting the log pipeline's routing configuration,
      not by inference from item 1 alone.
- [ ] A test audit event, triggered in a non-production environment (e.g. a
      `secret_viewed` event from viewing a test secret), appears in the
      captured destination — not just in the process's own stderr, but in
      wherever the log pipeline is expected to have delivered it.
- [ ] The captured destination's retention and tamper-evidence
      configuration match items 3 and 4 above.

## References

- `docs/adr/0004-audit-emission.md` — "Operational dependency" section, the
  source this runbook translates into operator action
- `docs/adr/0001-no-local-datastore.md` — the stateless constraint that
  makes retention the deployment's responsibility, not Nucleus's
- `docs/requirements/Audit-and-Compliance.md` — `AUD-A06`'s binding text and
  `unit, manual` test layer
- `test/nucleus/audit/sink/device_test.exs` — the automated unit half of
  `AUD-A06`
