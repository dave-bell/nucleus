# ADR-0004: Audit Emission

## Status

Accepted — 2026-08-11

Decided on [EN-5](https://github.com/dave-bell/nucleus/issues/5). Builds on
`0001-no-local-datastore.md`.

The wiki's `ADR-0003` (Compliance Audit Logging), under `docs/requirements/`,
describes the earlier Python prototype's two-tier audit design and is
**reference only**. Where this ADR reaches the same conclusion — the field
list, the `X-Forwarded-For` extraction algorithm — it is because that
conclusion was re-tested against this stack, not by inheritance. The sections
below say explicitly which decisions carry over and which change shape
because this is Elixir/Plug rather than FastAPI/Python.

## Context

Three of the Secrets actions — `secret_created` (SEC-A09), `secret_viewed`
(SEC-A03), `secret_updated` (SEC-A06) — must produce a compliance-grade audit
record, in a SOC2 (CC7.2) / HIPAA (164.312(b)) context. The wiki's
[Audit & Compliance](https://github.com/dave-bell/nucleus/wiki/Audit-and-Compliance)
page states four constraints a plain `Logger.info` call does not satisfy:

- **AUD-A02** — the value touched is never recorded, only the path
- **AUD-A05** — structured and machine-parseable, with a plain-text mode for
  local development that does not change *which* events are recorded
- **AUD-A06** — a distinct output stream from application logs, so audit
  records can be retained independently of routine logging noise
- **AUD-A07** — the write is synchronous, so a record cannot be lost to
  buffering or asynchronous delivery

## Decision

### `Logger` is bypassed entirely

Elixir's `Logger` is asynchronous by default and switches to synchronous
delivery only under overload (`sync_mode_qlen`) — "usually synchronous" is
not the same guarantee as AUD-A07 requires. `Logger` handlers can also drop
messages under overload protection, and a dropped audit record is a
compliance failure, not a performance trade-off. Sharing `Logger` would also
put audit records and application logs on the same pipeline, in tension with
AUD-A06.

`Nucleus.Audit.emit/2` never calls `Logger`. It formats a record and writes
it through a `Nucleus.Audit.Sink` directly.

### A `Sink` behaviour, two implementations

```elixir
@callback write(iodata()) :: :ok
```

- `Nucleus.Audit.Sink.Device` (default) — `IO.write/2` to a configured
  device, `:stderr` unless overridden. `IO.write/2` to a device is
  synchronous, so AUD-A07 holds by construction: the call does not return
  until the write has happened.
- `Nucleus.Audit.Sink.Test` — delivers the record to a registered test
  process instead. EN-8's `AuditCase` and its `refute_audit_contains/1`
  helper are built on this.

Using `:stderr` as the default gives AUD-A06 for free: application logs go
to `:stdout` (`Logger`'s default), audit records to `:stderr`, and a
container runtime can route the two streams separately with no application
change. `AUDIT_DEVICE` overrides to `:stdout`, a file path, or any other IO
device (a `pid`, e.g. a `StringIO` process for tests).

### Sink failures propagate, never rescued

`emit/2` has no `rescue` around the sink call. If the device write fails —
disk full, pipe closed — the exception reaches the caller. A silently
swallowed failure would look identical to a successful audit record from
every other part of the system, which is a worse failure mode than a crash:
the crash is visible, and AUD-A07 is not satisfied either way. The
Secrets features wiring these events (SEC-S4/S5/S6) get no automatic
retry or fallback; a failed audit write fails the action it was auditing.

### The struct is the AUD-A02 defence, not a convention

`Nucleus.Audit.Event` has no field named `value`, `secret`, `plaintext`, or
`new_value` — there is no key for a call site to pass one through by
accident. `emit/2` rejects any keyword key outside a fixed struct field list,
and separately rejects any key inside `details` outside a **per-event**
allowlist built from the wiki's event catalogue
(`docs/requirements/Audit-and-Compliance.md`). A permissive `details: map()`
would have reopened exactly this hole, since nothing would then stop a
`value` key from hiding inside it. The per-event required/allowed field
lists live in `Nucleus.Audit.Event.spec/1`.

The `@type event` union covers all eleven catalogued events, so a future
feature does not invent its own spelling — only the three Secrets events are
wired to a call site by this ticket. `auth_failure` and the Nomad Variable
and M2M events are defined but unused until EN-6 and their owning features.

### Format is decided strictly after recording, never before

`Nucleus.Audit.Format.encode/2` takes an already-built `%Event{}` and a
format (`:json` or `:text`); it adds, drops, or renames nothing. AUD-A05
requires the recorded *event set* to be format-independent, so formatting is
the last step, downstream of every validation `emit/2` performs — a
formatter cannot make a field disappear that validation already decided
belongs in the record.

`:json` is the default and the only format supported in any deployed
environment: one `Jason`-encoded record per line, newline-terminated,
`timestamp` as ISO 8601 UTC. `:text` (the dev default) is one
human-readable line, `key="quoted value"` pairs, with `%` and `{}` handled
safely because every value is quoted and escaped — a resource path
containing either cannot be mistaken for a field delimiter.

### Source IP: first `X-Forwarded-For` entry, peer fallback, never raises

Re-derived for `Plug.Conn` from the wiki ADR's algorithm:
`X-Forwarded-For: client, proxy1, proxy2` uses the first entry (the original
client); a direct connection with no proxy in front (a health check, local
dev) falls back to `Plug.Conn.get_peer_data/1`. `Nucleus.Audit.Source.from_conn/1`
never raises — a malformed header, or a peer lookup that itself fails, both
fall through to `nil`, because source IP is audit context, not a value
anything should crash the request over.

`Nucleus.Audit.Source` deliberately knows nothing about LiveView sockets. As
the ticket notes, `X-Forwarded-For` is unavailable on the socket after the
initial connection — capturing it during `on_mount` via
`get_connect_info/2` and carrying it in the auth scope is EN-6's job, not
this module's.

## Consequences

### Positive

- AUD-A02, AUD-A05, AUD-A06, and AUD-A07 are each satisfied by construction —
  a struct with no `value` field, a synchronous device write, a distinct
  default stream, and a sink call with no `rescue` — rather than by
  discipline at each call site.
- The full event catalogue exists in one place (`Nucleus.Audit.Event`)
  before any feature beyond Secrets needs it, so later tickets extend a
  table instead of inventing field names.
- `Nucleus.Audit.Sink.Test` gives EN-8's `AuditCase` a way to assert on
  emitted records without touching `:stderr` or parsing text output.

### Negative

- **Nucleus persists no audit history of its own.** There is no query
  interface, no local store, and no way to answer "show me every access to
  this secret" from within Nucleus. This follows directly from the
  stateless constraint in `docs/adr/0001-no-local-datastore.md` — see that
  ADR's "No Local Datastore" consequence: *"Audit records must go to an
  external log pipeline; there is no local option."*
- A raising sink means a transient write failure (a full disk, a broken
  pipe on `:stderr`) fails the audited action itself, not just the audit
  write. This is deliberate — see "Sink failures propagate" above — but it
  is a real availability trade-off, not a free guarantee.
- `AUDIT_DEVICE` pointed at a file path opens that file once at boot
  (`config/runtime.exs`) and keeps the handle for the life of the process.
  Log rotation of that file (e.g. by an external tool renaming it) is not
  handled — the deployment's log pipeline should prefer `:stderr`/`:stdout`
  and let the container runtime do rotation, rather than relying on this
  path.

### Operational dependency — external retention is not optional

**Audit records are not persisted by Nucleus.** Retention, tamper-evident
storage, and the 1–7 year retention window the wiki ADR mentions for
SOC2/HIPAA are entirely the deployment's log pipeline's responsibility — a
container runtime or log shipper capturing `:stderr` into append-only,
tamper-evident storage with the required retention period. This is a real
operational dependency for any Nucleus deployment claiming SOC2/HIPAA
compliance, not an implementation detail, and it is written down here so it
is not assumed.

## Alternatives considered

**Writing audit records through `Logger` with a dedicated handler.**
Rejected — see "`Logger` is bypassed entirely" above. A `:logger` handler
tuned for `sync_mode_qlen: 0` approximates synchronous delivery but is not
guaranteed synchronous, and AUD-A07 requires the guarantee, not the
approximation.

**Rescuing sink failures into a logged warning and continuing.** Rejected.
A rescued audit failure is indistinguishable from a successful one to
everything downstream of `emit/2` — the action it was auditing completes
looking compliant when it was not audited at all. AUD-A07 exists precisely
to rule this out.

**A free-form `details: map()` with no per-event allowlist.** Rejected. It
would satisfy the struct's own field list while reopening the exact hole the
struct closes — nothing would stop a `secret_created` call site from adding
`details: %{value: "..."}`.

**Deriving source IP handling for LiveView sockets in
`Nucleus.Audit.Source` itself.** Rejected. `X-Forwarded-For` is not
available on the socket after the initial connect; capturing it belongs to
`on_mount` and the auth scope (EN-6), not to a module whose only input is a
`Plug.Conn`.

## References

- EN-5 — the deciding issue, including the full implementation plan
- `docs/adr/0001-no-local-datastore.md` — the stateless constraint that
  makes external retention the deployment's responsibility, not Nucleus's
- Wiki [Audit & Compliance](https://github.com/dave-bell/nucleus/wiki/Audit-and-Compliance),
  [ADR-0003](https://github.com/dave-bell/nucleus/wiki/ADR-0003-Compliance-Audit-Logging)
  — reference only; prior art, not authority
- `docs/requirements/Audit-and-Compliance.md` — the binding `AUD-A01`–`A07`
  actions and the complete event catalogue this module's field lists are
  built from
- `.opencode/context/project-intelligence/decisions-log.md` — "No Local
  Datastore" decision, noting audit records go to an external log pipeline
- EN-8 — the contract test harness whose `AuditCase` depends on
  `Nucleus.Audit.Sink.Test`
- SEC-S4/S5/S6 — wire the three Secrets events at their call sites; EN-6 —
  auth, `auth_failure`, and LiveView source-IP capture
