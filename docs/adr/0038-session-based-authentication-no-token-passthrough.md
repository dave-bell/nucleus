# ADR-0038: Session-Based Authentication, No Token Passthrough

## Status

Accepted — 2026-09-29

Decided on [AUTH-D1](https://github.com/dave-bell/nucleus/issues/111). Builds on
`0002-backend-adapter-boundaries.md` (the `:auth_expired` error kind) and
`0005-deferred-authentication.md` (the `Nucleus.Scope` seam this ADR settles the
shape of).

## Context

`0005-deferred-authentication.md` built `Nucleus.Scope` as a seam so Secrets and
every LiveView after it could read identity from one struct regardless of
whether authentication was real yet. It deliberately left two questions open,
both recorded in `living-notes.md`:

1. How does a signed-in user's access token pass through a long-lived LiveView
   socket, when the HTTP request that authenticated it is gone?
2. Do the wiki's `AUTH-A01`–`A11` — written against an earlier prototype's React
   SPA and bearer-token API — still describe the intended flow for a
   server-rendered LiveView application?

Both were raised, discussed, and settled directly with the product owner ahead of
this ticket (see the issue's own Context section). `AUTH-D1`'s job was to record
that settlement in the wiki and this codebase's own context files — not to
re-litigate it. This ADR exists because the settlement itself is an
architectural reversal, not because the ticket that recorded it did any new
analysis: `business-domain.md`'s Core Model and `technical-domain.md`'s
Technical Constraints both named "Token passthrough" as a binding, adopted
principle since the project's first week. Removing it changes what every future
backend-boundary ticket (`EN-13`, and any that follow) is allowed to build.

## Decision

### Token passthrough is dropped, not narrowed

Question 1 does not resolve to one of `living-notes.md`'s three options — (a) a
session-carried token, (b) a socket-held token with a refresh path, or (c) a
per-user credential-holder process. None apply, because there is no longer a
user-owned access token past the sign-in callback to carry, refresh, or hold.
Nucleus exchanges the Cognito authorization code for tokens once, server-side,
writes a session (user id, email, `signed_in_at`), and discards every token
immediately — `Nucleus.Scope.token` and `Nucleus.TenantApi.Http`'s
`Authorization: Bearer` header path (both built by EN-6/EN-3 as the seam
question 1 anticipated) become dead code once a future ticket removes them.
Every backing API is reached with its own service credential instead —
Parameter Store already does this via an assumed AWS role
(`docs/adr/0002-backend-adapter-boundaries.md`); `EN-13` (issue #112) is the
tracked follow-up that deletes the now-unused token plumbing and settles the
Tenant API's own credential type, the one part of this question this ticket
does not close.

### The eleven `AUTH-*` actions are re-verified and amended, not reinterpreted

Question 2 resolves the way its own `living-notes.md` entry required: by
re-verifying each action against the LiveView design and amending the wiki
where it genuinely differs, never by silently building something the wiki
didn't say. `Authentication-and-Access.md` is rewritten wholesale for a
Cognito-Hosted-UI-plus-server-callback session model: `AUTH-A02` gains
`state`/`nonce` verification and a confidential client; the old `A06`/`A07`
merge into one "no valid session redirects to sign-in" action; `A08` is
replaced outright (no access-token refresh exists — there is no access token);
`A11` (identity display) is removed, folded into `NAV-A08`, which already
covered it; three actions are added — `A12` (view active sessions, built on
`Phoenix.Presence`), `A13` (terminate another user's session, with no
additional authorization group — an accepted risk mitigated by the
`session_terminated` audit event), and `A14` (a terminated tab's static
"session ended" page on reconnect). Retired IDs (`A07`, `A11`) are left as
gaps, not renumbered — the same convention `M2M-A09`'s drop already
established — so every action ID already cited by a test name or bug report
stays valid.

### `SEC-A18` is reworded to the distinction ADR-0002 already drew

`SEC-A18`'s prior wording — "the user is told their session has expired and
asked to re-authenticate" — conflated two different credential expiries.
`docs/adr/0002-backend-adapter-boundaries.md`'s `:auth_expired` kind already
states plainly that it "describes *Nucleus's* credentials for a backend — an
expired assumed role — not the end user's session." With no user token ever
forwarded, the *only* credential that can expire mid-session on the Secrets
path is Nucleus's own `TENANT_ROLE_ARN` session. `SEC-A18` now says so: a
self-healing retry, no user re-authentication, no redirect to sign-in. A user's
own session expiring is `AUTH-A08` (idle timeout / max age), which does
redirect — a separate action on a separate page, for a separate reason.

### Session lifetime has exactly one mechanism: two timers, no refresh

`SESSION_MAX_AGE` (default 8h) and `SESSION_IDLE_TIMEOUT` (default 15m) are the
only session-lifetime mechanism `AUTH-A08` describes. There is no silent
refresh to build, because there is no access token whose lifetime silent
refresh would extend. Every HTTP request and every LiveView mount
independently re-validates signature, both timers, and a termination check;
`AUTH-A05` states this is enforced at request/mount granularity only, never at
`handle_event` granularity, since there is no per-event token check to
protect.

### Cross-cutting requirement pages follow the same session model

`Platform-Operations.md` drops `OPS-A04` (a frontend runtime-config endpoint —
there is no frontend left to configure) and `OPS-A07` (bearer tokens never via
cookies — the session *is* now a cookie, so the rule is obsolete, not
satisfied) outright, gaining `COGNITO_CLIENT_SECRET`, `SESSION_MAX_AGE`, and
`SESSION_IDLE_TIMEOUT` in its configuration reference; `COGNITO_DOMAIN` becomes
required (the Hosted UI sign-out redirect needs it unconditionally, not only
when a frontend happens to ask for it). `Audit-and-Compliance.md` gains
`sign_in`, `sign_out`, and `session_terminated`, and narrows `auth_failure` to
callback-time failures only — a routine "never signed in" visit is
deliberately unaudited, the same reasoning `AUTH-A06` states. `Test-Strategy.md`
corrects its `auth.spec.ts` reference: no browser E2E tool exists in this repo
(`docs/adr/0008-test-strategy.md`), so the real Hosted UI round-trip stays a
manual/staging check, and `TEST_COGNITO_USER`/`PASSWORD` are dropped as
env vars nothing in this repo's test suite can use.

## Consequences

### Positive

- Both `living-notes.md` open questions this ADR closes were the two oldest
  unresolved items tracked since `0005`; nothing forward-looking about
  authentication remains open except the Tenant API's credential type
  (`EN-13`).
- `EN-13`'s scope is now fully bounded: delete `Nucleus.Scope.token`'s only
  consumer (`Nucleus.TenantApi.Http`'s `Authorization` header) and settle one
  credential type. No design work remains for that ticket.
- Every `AUTH-*` ID already cited anywhere (tests, this repo's own context
  files, other tickets' bodies) stays valid — the gap convention means nothing
  is silently renumbered out from under an existing citation.
- `SEC-A18`'s reword closes a real confusion `docs/adr/0002` had already
  flagged as a risk (`SEC-A18 handles the [user-session] latter` — written
  before this ticket, now made textually true).

### Negative

- **This ADR records a decision made in conversation, not one this ticket's
  own analysis produced.** The alternatives below were the product owner's to
  weigh, not this ticket's; they are recorded here for completeness, not as
  evidence of an independent trade-off study.
- **No `lib/` change lands with this ticket.** `Nucleus.Scope.token` and
  `Nucleus.TenantApi.Http`'s Bearer-header branch are now known-dead code
  (unreachable since `token` is always `nil`, per `0005`) but are not removed
  until `EN-13`. A reader of `lib/nucleus/tenant_api/http.ex` today will still
  see code shaped for a decision this ADR reverses, until that ticket lands.
- **`Phoenix.Presence`-backed active sessions (`AUTH-A12`) and cross-user
  termination (`AUTH-A13`) are new requirements with no implementation
  ticket yet identified.** This ADR fixes their shape; it does not schedule
  their build.

## Alternatives considered

**Keep token passthrough, solve it for LiveView (`living-notes.md`'s option
(a), (b), or (c)).** Rejected by the product owner ahead of this ticket. A
server-rendered control plane with no frontend has no reason to carry a
user's access token at all once every backend is reached through its own
service credential — solving a hard problem this application's own
architecture makes unnecessary.

**Leave `SEC-A18` as "re-authenticate" and treat it as a wording accident
rather than a real ambiguity.** Rejected. `docs/adr/0002` already drew the
`:auth_expired`-vs-user-session line in code-facing prose; leaving the wiki's
user-facing wording to contradict that distinction would have left the
binding requirement and the ADR disagreeing indefinitely.

**Renumber `Authentication-and-Access.md`'s actions contiguously (`A01`–`A12`)
instead of leaving gaps at the retired `A07`/`A11`.** Rejected, matching
`M2M-A09`'s precedent: renumbering breaks any existing citation of a
higher-numbered action by ID, for a purely cosmetic gain.

## References

- `AUTH-D1` (issue #111) — the deciding issue, including the full page-by-page
  amendment table
- `docs/adr/0005-deferred-authentication.md` — the seam this ADR settles the
  shape of; its own "Negative consequences" section named both questions this
  ADR closes
- `docs/adr/0002-backend-adapter-boundaries.md` — the `:auth_expired` kind
  `SEC-A18`'s reword now matches in the wiki, not only in code
- `docs/requirements/Authentication-and-Access.md`,
  `docs/requirements/Secrets.md`, `docs/requirements/Platform-Operations.md`,
  `docs/requirements/Audit-and-Compliance.md`,
  `docs/requirements/Application-Shell-and-Navigation.md`,
  `docs/requirements/Test-Strategy.md`, `docs/requirements/Home.md` — the
  amended wiki pages
- `.opencode/context/project-intelligence/living-notes.md` — both open
  questions, now in the Archive
- Issue #112 (`EN-13`) — removes `Nucleus.Scope.token`'s only consumer and
  settles the Tenant API's credential type
- Issue #15 (`SEC-S7`) — implements `SEC-A18`'s reworded behavior in code
