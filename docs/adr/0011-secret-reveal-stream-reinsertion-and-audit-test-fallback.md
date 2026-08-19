# ADR-0011: Secret Reveal — Stream Re-Insertion, Audit Identity, and the Test Sink's `$callers` Fallback

## Status

Accepted — 2026-08-18

Decided on [SEC-S4](https://github.com/dave-bell/nucleus/issues/12). Builds on
`0010-secrets-listing-gate-collapse-and-dom-ids.md` (the ARN-hashed DOM id
this ticket re-streams against) and `0004-audit-emission.md` (the sink and
per-event allowlist this ticket is the first to actually wire to a call
site).

## Context

SEC-S4 implements `SEC-A03`–`A05`: reveal a secret's plaintext value, hide it
again, and handle a failed reveal without an unexplained blank state. Three
things the plan left open needed settling during implementation:

1. `Nucleus.Secrets.list/2` returns `SecretRef` (no `value` field);
   `reveal/3` is the first function to call `Store.get_secret/2` and produce
   a `Secret` (which has one). `SecretsLive` streams `SecretRef` structs —
   what does a reveal or hide actually re-stream, and does the plaintext
   ever touch the stream's own state?
2. This is the first real call site for `Nucleus.Audit.emit/2` — EN-5 built
   the emitter and its allowlist, but nothing before this ticket actually
   called it from application code. What identity does `user:` carry, and
   does it hold up once a signed-in user's Cognito token has no `email`
   claim (a case `Nucleus.Scope.audit_user/1` already exists to handle)?
3. `Nucleus.Audit.Sink.Test` delivers a record to whichever process called
   `register/1` — by design, since every prior audit-emitting call ran
   directly in the test process. `reveal/3` is now called from inside a
   `handle_event/3` in a *mounted LiveView*, a distinct GenServer process a
   test never calls `register/1` from. Testing "hiding emits no audit
   event" and "reveal → hide → reveal emits two events" — both explicitly
   asked for in the ticket's test plan — requires the sink to reach the test
   process from inside that spawned view.
4. `SEC-A05` requires `:auth_expired` be handled without crashing, but
   `SEC-S7` (the ticket that owns that failure mode's shared retry handler)
   is still open. What does `reveal/3`'s failure path show in the meantime?

## Decision

### Re-stream a converted `SecretRef`, never the `Secret`

`handle_event("reveal"/"hide", ...)` converts the `Secret` back to a
`SecretRef` (`key`, `path`, `arn`, `last_modified` — dropping `value`) before
`stream_insert/3`. The stream itself never carries a struct with a `value`
field, on either branch — the plaintext lives only in a new `:revealed`
assign (`%{key => Secret.t()}`), read directly in the template. This means
an accidental `inspect(@streams.secrets)` in a future debugging session, or
a LiveView introspection tool that dumps stream state, still cannot leak a
value; only `@revealed` can, and only for keys the user actually revealed.

Re-streaming (rather than only updating `:revealed`) is required by
`AGENTS.md`'s rule that an assign changing content *inside* a streamed item
must re-insert that item — `:revealed` is not itself part of the stream
item, so without this the row would not re-render on reveal or hide at all.
The DOM id is unaffected: `dom_id/1` now matches on both `SecretRef` and
`Secret` (same ARN, same hash), so a reveal or hide never changes which row
it targets.

### Audit `user:` is `Nucleus.Scope.audit_user/1`, not a raw `email` read

`reveal/3` emits `user: Scope.audit_user(scope)`, not `scope.user &&
scope.user.email`. `audit_user/1` already existed (built with EN-6's
`Nucleus.Scope`) for exactly this: Cognito access tokens can carry no
`email` claim, so it falls back to `username`, then `"anonymous"`, and
guards against a blank-but-non-nil `email` being recorded as the audit
user. `Nucleus.Audit.emit/2`'s own `nil`-to-`"anonymous"` fallback only
covers an absent field — it does not know about `username` or reject `""` —
so calling it with a raw `email` read would have silently misattributed a
real Cognito user to `"anonymous"` the first time `email` was absent,
undetectable in this ticket's own tests since the dev scope fixture always
populates `email`. Every future `Audit.emit/2` call site (`SEC-S6`'s
`secret_created`, `SEC-S5`'s `secret_updated`) should call `audit_user/1`
for the same reason, not repeat the raw read.

### `Nucleus.Audit.Sink.Test` falls back to `Process.get(:"$callers")`

`write/1` now checks the writing process's own registration first (existing
behaviour, unchanged for every context-level test that emits directly), and
falls back to the first pid in `$callers` when none is set. Empirically,
`Phoenix.LiveViewTest` sets `$callers` on a mounted view's process to the
test process that called `live/2` — the same ancestry chain Ecto's SQL
Sandbox relies on for its own process-allowance mechanism, already present
in this stack's dependencies with no additional wiring needed. This reaches
exactly the process that already called `Nucleus.Audit.Sink.Test.register/1`
in `AuditCase`'s `setup`, with no LiveView code aware that a test is
watching, and no change to `register/1`'s existing per-process contract.

### `:auth_expired` gets local, honest copy — not a borrowed handler

The ticket's plan called for delegating to "the shared handler `SEC-S7`
introduces." `SEC-S7` (issue #15) is still open, so `reveal/3`'s failure
`case` renders its own flash text for `:auth_expired`
("This environment's secrets can't be reached right now.") rather than
inventing a cross-cutting handler function prematurely — `SEC-S7`'s own
plan says the handler must end up in exactly one place, and building it
here first would mean `SEC-S7` either keeping this copy as-is or rewriting
a call site outside its own ticket. This is a divergence from the plan as
written, tracked so `SEC-S7` replaces it deliberately rather than
discovering it by accident.

### Key validation stays a minimal, explicitly weaker deny list

`reveal/3` rejects `..`, `/`, `\`, and a null byte in `key` before calling
`Store.get_secret/2` — the minimum needed to stop a forged `phx-value-key`
from reaching `Path.build/2` and resolving into another environment's
bucket. This is deliberately **not** as strong as
`Environments.validate_name/1`, which layers a positive charset allowlist
and a length cap on the same denylist, for the reason that module's own doc
gives: a denylist alone lets percent-encoded traversal and unicode
lookalikes through. `SEC-S6` (issue #14) owns the authoritative key rules
for secret creation; this validator is provisional pending that ticket's
consolidation, not a claim of equivalent strength.

## Consequences

### Positive

- No path from a reveal or hide to a value leaking into stream state,
  independent of what leaks into `:revealed` — two different failure modes
  would have to both go wrong for a value to reach the DOM outside the
  template's own `@revealed` read.
- `Nucleus.Audit.Sink.Test`'s `$callers` fallback is generic — `SEC-S5`
  (`secret_updated`) and `SEC-S6` (`secret_created`) get audit-assertion
  support in their own LiveView tests for free, with no per-ticket sink
  workaround to invent.
- `audit_user/1` is now proven at a real call site, not just defined and
  doctested.

### Negative

- The `:auth_expired` flash copy written here is throwaway the moment
  `SEC-S7` lands — a deliberate, tracked cost, not an oversight.
- The key validator's deny list is a second, slightly different copy of
  logic that already exists once in `Environments.validate_name/1`. `SEC-S6`
  inherits an explicit obligation to consolidate rather than leave two
  slightly-different validators live.

## Alternatives considered

**Keep streaming `Secret` structs directly, relying on the template to
never render `.value` for an unrevealed row.** Rejected — this is exactly
the "single struct, optional value, one forgotten branch away from a leak"
shape `Nucleus.Secrets.Secret`'s own moduledoc was written to make
impossible. Converting back to `SecretRef` before `stream_insert/3` keeps
that guarantee intact through this ticket's own change.

**Register the mounted view's pid explicitly from each test, via some new
test helper, instead of extending the sink.** Rejected — there is no public
API to execute code inside an already-running LiveView process from a test
process; `register/1` stores its argument in the *calling* process's own
dictionary, so calling it with `view.pid` from the test process would only
overwrite the test process's own entry, not reach the view. The `$callers`
fallback is the only mechanism available that runs inside the view process
itself without adding test-awareness to `NucleusWeb.SecretsLive`.

**Build `SEC-S7`'s shared `:auth_expired` handler now, since this ticket
needs the copy anyway.** Rejected — pulls a not-yet-decided ticket's design
forward under time pressure from an unrelated one; `SEC-S7`'s plan expects
to consolidate every `:auth_expired` branch in the codebase, not just this
one, into a single function.

## References

- SEC-S4 (issue #12) — the deciding issue
- `docs/adr/0010-secrets-listing-gate-collapse-and-dom-ids.md` — the
  ARN-hashed DOM id this ticket's re-streaming preserves
- `docs/adr/0004-audit-emission.md` — the sink and per-event allowlist this
  ticket is the first to call from application code
- `docs/adr/0009-environment-validation-ladder.md` — the denylist-vs-allowlist
  reasoning this ticket's key validator is explicitly weaker than
- `AGENTS.md` — the stream re-insertion rule this ticket's reveal/hide
  handlers follow
- Wiki [Secrets](https://github.com/dave-bell/nucleus/wiki/Secrets)
  `SEC-A03`–`A05`; [Audit & Compliance](https://github.com/dave-bell/nucleus/wiki/Audit-and-Compliance)
  `AUD-A01`, `AUD-A02`
