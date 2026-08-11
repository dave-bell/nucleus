# ADR-0005: Deferred Authentication

## Status

Accepted — 2026-08-11

Decided on [EN-6](https://github.com/dave-bell/nucleus/issues/6). Builds on
`0002-backend-adapter-boundaries.md` (the boot-warning pattern) and
`0004-audit-emission.md` (the `source_ip`/`X-Forwarded-For` extraction
algorithm, and the explicit handoff of LiveView-socket source-IP capture to
this ticket).

**Numbering note**: the issue text names this file
`0004-deferred-authentication.md`, written before `0004-audit-emission.md`
(EN-5) landed. `0004` was already taken by the time this ticket started, so
this ADR is `0005` — a sequencing collision in the ticket text, not a
decision to revisit.

The wiki's [ADR-0002](https://github.com/dave-bell/nucleus/wiki/ADR-0002-Security-Hardening)
§6 (audit identity fallback) and §7 (never expose a raw token in logs), under
`docs/requirements/`, describe the earlier Python prototype and are
**reference only**. Where this ADR reaches the same conclusion — the
email-then-username-then-anonymous fallback — it is because that rule was
re-verified for this stack, not inherited by citation.

## Context

`AGENTS.md` is explicit that Phoenix 1.8 LiveViews require a `current_scope`
assign, and that omitting it produces its own error class. Every audit record
(EN-5) needs a `user` and a `tenant`. `SEC-A18` needs somewhere for "your
session has expired, re-authenticate" to eventually hang off. Secrets
(SEC-S1 onward) cannot be built against none of this.

At the same time, real authentication is deliberately **not** ready to build.
The wiki's [Authentication & Access](https://github.com/dave-bell/nucleus/wiki/Authentication-and-Access)
page defines `AUTH-A01`–`AUTH-A11` — Cognito Hosted UI, federated SSO, PKCE,
group membership, silent refresh — against an earlier prototype with a React
SPA. `living-notes.md` records two open questions neither settled by this
ticket:

1. How does a signed-in user's access token pass through a long-lived
   LiveView socket, when the original HTTP request that authenticated it is
   gone?
2. Do the eleven `AUTH-*` actions still describe the intended flow now that
   there is no SPA to redirect?

This ADR is the seam that lets Secrets proceed without either question being
open a blocker: the *shape* of an authenticated request is fixed now, so that
building the real thing later is a substitution behind that shape, not a
refactor of every LiveView and every backing-API call site that reads it.

## Decision

### `Nucleus.Scope` is the only shape anything downstream reads

`lib/nucleus/scope.ex` defines `user`, `tenant`, `token`, `scopes`, and
`source_ip`. No caller — a LiveView, a plug, an audit call site — reads
identity from anywhere else. Whether that struct was built by a real sign-in
or (for the whole of this ticket) a single configured dev identity is
invisible past `Nucleus.Scope.Provider.build/1`.

### `token` exists now and is always `nil`

Retrofitting a `token` field later would touch every backing-API call site
that needs to pass it through. The field is added now, deliberately unused,
so that the future auth ticket's job is to populate it, not to invent it and
thread it through code that has never seen a token-shaped argument. Nothing
in this ticket fabricates a value for it — a fake token would be worse than a
missing one, since it would look like passthrough was already solved.

### `audit_user/1`: email, then username, then `"anonymous"`

Re-verified from the wiki's ADR-0002 §6, not inherited: Cognito access tokens
carry no `email` claim, only ID tokens do, and the access token is what
`AUTH-A11`'s API contract forwards to backing APIs. An audit emitter reading
only `email` would silently record `"anonymous"` for every real user once
auth exists. Encoding the fallback in `Nucleus.Scope.audit_user/1` now, while
the only caller is `Nucleus.Scope.verify_provider_at_boot!/0`'s warning,
means EN-5's audit call sites inherit the correct behaviour rather than
rediscovering it.

### Two providers behind one behaviour, selected by one flag

`Nucleus.Scope.Provider` declares `@callback build(context :: map()) ::
{:ok, Scope.t()} | {:error, term()}`. `Nucleus.Scope.Provider.Disabled` (the
default) never fails and returns a scope built from a single configured dev
identity. `Nucleus.Scope.Provider.Cognito` is a stub that raises
unconditionally, naming `AUTH-A01..A11`.

`AUTH_ENABLED` (`config/runtime.exs`, default `false`) selects between them.
Unlike `SECRETS_BACKEND`/`TENANT_API_BACKEND` (`docs/adr/0002`), this is not a
per-boundary developer convenience — it is the one switch between "no
authentication exists" and "real authentication, which does not exist yet
either." An unrecognised value raises at boot, the same defence
`AUDIT_FORMAT` uses (`docs/adr/0004-audit-emission.md`): a typo here must not
silently keep the disabled provider.

### The dev identity is compile-time config, not an environment variable

`Nucleus.Scope.Provider.Disabled` reads its assumed email and scopes from
`config :nucleus, Nucleus.Scope.Provider.Disabled, email: ..., scopes: ...`
(set in `config/dev.exs`; `config/test.exs` overrides it to a
distinguishable value). This differs from the issue text's literal
`DEV_USER_EMAIL`/`DEV_USER_SCOPES` environment variables: with
`AUTH_ENABLED=true`, the equivalent values come from the minted JWT's claims,
not from an environment variable — so there is no runtime configuration
surface for this identity to still occupy once real auth exists, and no
env-var-vs-JWT precedence question to get wrong later.

`TENANT_NAMESPACE` remains a `config/runtime.exs` environment variable,
because the tenant a deployment serves is infrastructure configuration, not
an identity claim — both providers will need it, not just `Disabled`.

### Boot verifies the provider unconditionally — warn or fail loudly

`Nucleus.Scope.verify_provider_at_boot!/0`, called from
`Nucleus.Application.start/2` alongside `Nucleus.Backend.warn_on_local_backends/0`,
calls `build/1` on whichever provider is configured, every boot, regardless
of which one that is:

- `Disabled.build/1` always succeeds, and the boot warning names the
  assumed identity, tenant, and scopes — the same rationale as EN-2's
  local-backend warning: make the insecure-but-convenient mode impossible to
  be in accidentally.
- `Cognito.build/1` always raises. Calling it at boot means an
  `AUTH_ENABLED=true` misconfiguration fails the *boot*, not the first
  request — a loud, early failure rather than a silent fallback to the
  disabled provider.

No `rescue` wraps this call. A rescued boot check would defeat the entire
point: the failure must stop the release from serving traffic.

### The plug captures `source_ip`; the LiveView hook carries it forward

`NucleusWeb.Plugs.AssignScope` builds the scope and assigns
`conn.assigns.current_scope` for the `:browser` pipeline, capturing
`source_ip` via `Nucleus.Audit.Source.from_conn/1` — the same function EN-5
built, at the one point a `Plug.Conn` (and so `X-Forwarded-For`) exists for a
LiveView request. It also puts the scope into the session, with `token`
forced to `nil` regardless of what the provider returned: the session is a
signed, not encrypted, cookie, and this is a defensive floor that costs
nothing today and rules out a future provider leaking a token into it by
omission.

`NucleusWeb.ScopeHook.on_mount/4` prefers that session-carried scope. When
there is none — a LiveView mounted outside the `:browser` pipeline, or a
socket with no prior request — it builds one fresh, reading `source_ip` from
`get_connect_info(socket, :x_headers)`, re-deriving the same
first-`X-Forwarded-For`-entry algorithm `Nucleus.Audit.Source` uses for a
`Plug.Conn`, because that module "deliberately knows nothing about LiveView
sockets" (`docs/adr/0004-audit-emission.md`) and capturing it here was
explicitly left to this ticket. `lib/nucleus_web/endpoint.ex`'s LiveView
socket now declares `:x_headers` in `connect_info` so the value is available
to read at all.

### Nothing renders an identity control in this ticket

`AUTH-A10` (sign-out) and `AUTH-A11` (identity display) are explicitly out of
scope. This ticket adds no LiveView and touches no template — the existing
`Layouts.app` does not render `current_scope` at all yet. EN-7 owns the
identity control and has already settled (in its own plan) on rendering no
sign-out control while auth is disabled, rather than a disabled one that does
nothing.

## Consequences

### Positive

- Every future LiveView and every EN-5 audit call site reads identity from
  one struct, regardless of whether auth is real yet.
- `AUTH_ENABLED=true` fails at boot, not on the first authenticated request —
  the same class of defence as `Nucleus.Backend`'s per-boundary mode
  validation.
- Adding real authentication later is bounded to `Nucleus.Scope.Provider.Cognito`
  and populating `token`; no LiveView, plug, or audit call site changes shape.

### Negative

- **The token-passthrough question is narrowed, not answered.** `token` has
  a fixed field and a fixed rule (never populate it here), but *how* a real
  token would be kept out of the session cookie, refreshed, or invalidated
  mid-socket is still open — see `living-notes.md`. The defensive
  `%{scope | token: nil}` in `AssignScope` is a floor, not a design for that
  future state.
- **The `AUTH-*` re-verification question is untouched.** This ADR reserves
  a seam shaped by the *current* eleven actions; if those actions turn out
  not to describe the intended LiveView flow, the seam's shape — not just
  its implementation — may need to change.
- **No LiveDashboard gating.** `living-notes.md`'s existing technical debt
  item (LiveDashboard at `/dev/dashboard` unauthenticated) is unaffected by
  this ticket; there is still no `:auth` boundary to gate it behind.

## Alternatives considered

**Building a minimal real sign-in flow now, deferring only group
membership.** Rejected. The issue's own context is explicit: token
passthrough over a LiveView socket and whether the eleven `AUTH-*` actions
still apply are both unresolved. A "minimal" real implementation would still
have to guess at both, and guessing now is more expensive to unwind than
building the seam and deferring the guess.

**Making `AUTH_ENABLED` per-boundary, like `SECRETS_BACKEND`.** Rejected.
Backend boundaries are swappable because the *pain* they solve (a
Terraform-provisioned IAM role) is per boundary. Authentication is the
security boundary itself — `docs/adr/0002-backend-adapter-boundaries.md`
already rules out an `:auth` boundary for the same reason.

**Reading the dev identity from `DEV_USER_EMAIL`/`DEV_USER_SCOPES`
environment variables, as the issue text literally proposes.** Rejected in
favour of compile-time config in `config/dev.exs`. With `AUTH_ENABLED=true`
those values come from the JWT, not the environment, so an env-var-based dev
identity would be a runtime configuration surface with no real-auth
counterpart to eventually replace it — a dead knob once auth ships, and a
second source of truth (env var vs. JWT claim) to reconcile in the meantime.

**Storing the whole `Nucleus.Scope` in the session, token included.**
Rejected. `token` is always `nil` in this ticket, so it is functionally
identical to forcing it to `nil` — but forcing it costs one line and removes
a future footgun: a provider change that starts populating `token` would
otherwise put it straight into a signed-but-unencrypted cookie by omission,
not by a decision anyone made.

## References

- EN-6 — the deciding issue, including the full implementation and test plan
- `docs/adr/0002-backend-adapter-boundaries.md` — the boot-warning pattern
  this ADR's `Nucleus.Scope.verify_provider_at_boot!/0` follows; "Authentication
  is never swappable"
- `docs/adr/0004-audit-emission.md` — `Nucleus.Audit.Source.from_conn/1`, and
  its explicit statement that LiveView-socket source-IP capture is this
  ticket's job
- Wiki [Authentication & Access](https://github.com/dave-bell/nucleus/wiki/Authentication-and-Access)
  (`AUTH-A01`–`A11`, deferred in full);
  [ADR-0002](https://github.com/dave-bell/nucleus/wiki/ADR-0002-Security-Hardening)
  §6/§7 — reference only; prior art, not authority
- `.opencode/context/project-intelligence/living-notes.md` — the
  token-passthrough and `AUTH-*` re-verification open questions, both
  narrowed but not closed here
- `AGENTS.md` — `current_scope` / `Layouts.app` convention; `on_mount` at the
  `live_session` level, not per-LiveView
- Issue #7 (EN-7) — wires `AssignScope`/`ScopeHook` into the router and
  renders the identity control, with no sign-out affordance while auth is
  disabled
- Issue #15 (SEC-S7) — the future consumer of the credential-expiry state
  this seam's `token` field exists for
