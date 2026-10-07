# ADR-0040: Cognito Sign-In and the In-Memory Session Lifecycle

## Status

Accepted — 2026-10-07

Decided on [AUTH-S1](https://github.com/dave-bell/nucleus/issues/113). Implements the
session model `0038-session-based-authentication-no-token-passthrough.md` settled and
`0039-tenant-api-service-credential.md` cleared the way for. Supersedes the deferred-authentication
half of `0005-deferred-authentication.md`: its `Nucleus.Scope` seam, `AUTH_ENABLED` switch and
disabled-by-default provider all stand, but `Nucleus.Scope.Provider.Cognito` no longer raises.

## Context

Until this ticket there was no sign-in route, no callback, no unauthenticated page, no OIDC
library, and a `Cognito` scope provider that raised unconditionally. `0038` fixed the shape —
exchange the authorization code once, server-side, write a session, discard every token, enforce
two timers at request and mount granularity — and `0039` removed the last user-token plumbing. What
was left was to build it, and several parts of building it were genuine decisions the ticket's own
body flagged: how to speak OIDC, where an idle clock can live when a LiveView socket cannot write a
cookie, and what "return to the page you were on" means for a mount that is never told a URL.

## Decision

### Sign-in is written directly on `jose` and `Req`, not on Ueberauth

`ueberauth_cognito` was evaluated against the source and rejected. It sends neither a `nonce` nor
a PKCE challenge and cannot be made to — the authorize parameters are fixed inside
`handle_request!` — so `AUTH-A02` as written (`state` checked, `nonce` verified in the ID token)
could not be met without forking it. It also brings its own Mint-based HTTP client, which the
`Req.Test` stubs `docs/requirements/Test-Strategy.md` prescribes cannot intercept and which
`AGENTS.md`'s `Req`-first rule rules out; it keeps access and refresh tokens in `conn.assigns`,
which `0038`'s "no token survives" would have to be re-proved against; and it refetches the JWKS on
every callback. `ueberauth_okta`, looked at as the example of a swap target, never validates the
ID token at all and checks no `nonce`, so "adding the matching Ueberauth package" would not have
bought an identity-provider change cheaply either — each strategy is its own implementation with its
own guarantees and data shapes.

Instead, `Nucleus.Auth.OIDC` is plain functions over `Req` and `jose` (the only new dependency, and
one `ueberauth_cognito` itself requires): it builds the authorize URL, exchanges the code, verifies
the ID token, and checks the group. Roughly 150 lines, tested against a generated RSA key and a
`Req.Test` stub.

**Cognito specifics are confined to two modules** — `Nucleus.Auth.Config` (the endpoint URLs, built
from the existing `COGNITO_*` settings) and `Nucleus.Auth.OIDC` (the `token_use` and
`cognito:groups` claims). An identity-provider change would be an edit to those two, not a hunt.
Generic OIDC discovery (`/.well-known/openid-configuration`) was considered to make it a
configuration-only change and declined: the project has moved identity providers once (Auth0 to
Cognito, on pricing) and does not expect to again, and discovery would add a startup fetch and a
failure mode for a flexibility nobody expects to use.

### The flow, and what is kept from it

`POST /sign-in` mints a random `state`, `nonce` and PKCE verifier, stores them in the session, and
redirects to the Hosted UI requesting `openid email` — no API scope. The callback treats the attempt
as spent whatever happens (the pending values are deleted first), then checks, in order: an
IdP-reported `?error=`, the pending sign-in, `state` (constant-time compare), the `code`, the code
exchange (confidential client, secret in an `Authorization: Basic` header, PKCE verifier sent), the
ID token (RS256 only via `JOSE.JWS.verify_strict`, then `iss`, `aud`, `token_use`, `exp`, `nonce`),
and `cognito:groups` against `COGNITO_ALLOWED_GROUP`. Every failure is a generic page, an
`auth_failure`, and no session; none can crash the request. `exchange_code/2` returns only the ID
token — the access and refresh tokens are never returned out of the module, and nothing is stored but
the claims the session needs (id, email, username, `signed_in_at`, `last_active`).

Signing keys are cached in `:persistent_term`; a token naming an unknown `kid` triggers exactly one
refetch (key rotation) before being rejected. A missing `exp` is treated as expired, not eternal.

### The session cookie is encrypted, and `Secure` outside dev and test

It now holds the user's email, and during sign-in the PKCE verifier, which is meant to stay private.
`encryption_salt` is added to the endpoint's session options (the LiveView socket uses the same list,
so mounts read it unchanged). `secure: true` comes from `config/config.exs`; `dev.exs` and `test.exs`
turn it off because dev is served over `http://localhost`. `Application.compile_env!` has no
fallback, so a missing setting is a compile error rather than a quietly insecure cookie. `SameSite=Lax`
stays: it is what lets the cookie ride the top-level redirect back from Cognito. Everyone is signed
out once on the deploy that adds the salt.

### An in-memory registry owns the idle clock, the expiry announcement, and "where the user was"

A LiveView socket cannot write a `Set-Cookie`, so socket activity cannot advance an idle clock kept in
the cookie. `Nucleus.Auth.SessionRegistry` — a supervised `GenServer` over an ETS table, reads
direct, writes serialized — holds one record per signed-in session, fed by HTTP requests, mounts,
navigation and throttled events, with one timer per session.

- **Timers are lazy.** Activity does not reschedule; when a timer fires it recomputes the real
  deadline from `last_active` and sleeps again if the session was active.
- **Expiry is announced exactly once.** `expire/3` is the single transition out of `:active`, atomic
  in the `GenServer`; only the caller that wins it emits `sign_out` (`reason=idle|max_age`) and
  broadcasts `"disconnect"` on the session's `live_socket_id`, closing every tab. The timer, a
  request and a mount can all find a session expired at about the same moment and it is still one
  event. A session the registry has never heard of is recorded as ended too, so a stale cookie
  replayed after a restart cannot announce twice. Once max age has passed, pruning replaces
  the full record with a minimal ended-status marker, which keeps the expiry-deduplication state.
  Markers are deleted three `max_age` periods after compaction. A stale cookie replayed after that
  is announced a second time, an accepted duplicate `sign_out`; it cannot revive a session, because
  `SessionCheck` rejects a cookie past max age before consulting the registry (this holds for
  `:terminated` markers too). If pruning wins before the deadline timer, it announces the expiry itself.
- **Max age needs no server state.** `signed_in_at` is in the cookie, so it is enforced from there
  and survives a restart; the registry's copy only lets the timer close open tabs on time.
- **It remembers the last path** each session was seen on. A mount is not told the page URL
  (`get_connect_info(socket, :uri)` is the *websocket's* URL, not the page's), so when a reconnecting
  tab finds its session ended, the registry — not the mount — knows what `AUTH-A09`'s "the page they
  were on" was. The path is sanitized again where it is used.
- **It is also the termination list `AUTH-A05` names.** Status `:terminated` and
  `terminate_session/2` exist as the seam for `AUTH-A13`; nothing in this ticket sets it.

**Single node.** The registry is per node. The service is not expected to scale horizontally; if it
ever does, sticky sessions keep a user's requests on the node holding their record. This is stated
here so that it is a decision rather than a discovery.

**A restart forgets.** A session the registry no longer holds falls back to the timestamps in its
cookie (`last_active` is advanced on every HTTP request) and is re-registered if still valid, which
can only err towards signing out early. Registration is conditional on absence, serialized with
logout and termination; recovery rejects an ended status that wins concurrently. A *terminated*
session is forgotten on restart too, so its cookie works
again until it ages out — a gap `AUTH-A13`'s ticket has to close, recorded in `living-notes.md`.

Presence was considered for the clock and rejected: its entries vanish when the last tab closes
(losing the activity history of a user who closes and reopens a tab), it keeps data per tab rather
than per session, and one session needs exactly one expiry announcement, not one per tab. Presence
stays for `AUTH-A12`'s active-sessions view, where per-tab data is the point.

### One validity check, two callers, and a hook that can halt

`Nucleus.Auth.SessionCheck.validate/2` answers "is this session still valid?" — no `"auth"` entry
(never signed in, or a cookie that failed decryption), max age, the registry's verdict, and the
cookie fallback for an unknown session — and counts a success as activity. It is called from exactly
two places so they cannot drift: `NucleusWeb.Plugs.AssignScope` for HTTP requests, which redirects to
`/sign-in?return_to=` and halts, and `NucleusWeb.ScopeHook` for LiveView mounts, which does the same
as `{:halt, redirect(...)}` before any LiveView's `mount/3` runs, so no tenant data is fetched.
`AUTH-A06`'s silence is preserved: a first visit or tampered cookie is not audited, and `auth_failure`
is never emitted by a redirect.

**`ScopeHook` was extended, not replaced.** The plan called for a new `AuthHook`. Making the existing
hook halt under the Cognito provider changes the same behaviour the requirement names ("unlike today's
`NucleusWeb.ScopeHook`, which never halts"), keeps the fixed `on_mount` order of `0006` literally true,
and avoids renaming a module referenced from many moduledocs and several ADRs. With auth disabled it
behaves exactly as before.

**No per-`handle_event` check.** `AUTH-A05` is scoped to request and mount granularity. What the hook
attaches is two *non-halting* hooks that only report activity: `:handle_params` (every navigation,
with its path) and `:handle_event` (clicks, edits, submits — throttled to one report per 30s per tab,
since a text field fires an event per keystroke). A user busy in one page keeps their session alive;
a tab left alone is closed by the expiry broadcast and, on its automatic reconnect, redirected.

**`AUTH-A09`'s "next interaction"** is therefore met by the broadcast-and-reconnect path, not by a
check on the next click: a click inside an already-connected tab is served until the tab is
disconnected, which happens at the deadline. A session ended by someone else (`AUTH-A13`) will take
the same path.

### Audit

`sign_in` (user, tenant, source IP) and `sign_out` (user, tenant, reason) are added to the catalogue.
`auth_failure` drops the `details.path` it was catalogued with and *required*: the wiki's field list is
user, tenant, source IP and reason, and a callback failure has no path. Reasons used: `idp_error:<code>`
(sanitized to `[a-z_]`, else `unknown`), `state_missing`, `state_mismatch`, `missing_code`,
`token_exchange_failed`, `token_endpoint_unreachable`, `invalid_id_token:<why>`, `not_in_authorized_group`.

### Logout ends the session, not just the cookie

`DELETE /logout` previously only dropped the cookie. With real sessions that would leave a copy of the
cookie working and let the timer later record a misleading `sign_out reason=idle`. It now ends the
session in the registry, records `sign_out reason=user`, closes the session's other tabs (the same
broadcast the timer uses), and lands on `/sign-in`. Ending the *Cognito Hosted UI* session as well
(`AUTH-A10`'s `/logout` redirect) remains `AUTH-S2`; until then the corporate IdP may sign the user
straight back in, which is commented where it would be discovered (`NucleusWeb.AuthController`).

### Configuration

`COGNITO_DOMAIN`, `COGNITO_REGION`, `COGNITO_USER_POOL_ID`, `COGNITO_CLIENT_ID`,
`COGNITO_CLIENT_SECRET`, `COGNITO_ALLOWED_GROUP` are all required when `AUTH_ENABLED=true`, checked at
boot by `Nucleus.Auth.Config.verify!/0` (which replaces `build/1` as the boot check, since there is no
session at boot). `SESSION_IDLE_TIMEOUT` (default 900) and `SESSION_MAX_AGE` (default 28800) are
**integer seconds** — the wiki gives only the defaults in words — and are validated in every
environment so a typo fails at boot.

## Deploy prerequisites

None of these are code, and the first two will make sign-in fail until they are done:

- **The callback URL must be registered on the sign-in app client.** Nucleus sends
  `NucleusWeb.Endpoint.url() <> "/auth/callback"` as `redirect_uri` on both the authorize request and the
  token exchange: `https://{PHX_HOST}/auth/callback` in production. Cognito rejects any URL not on the
  client's allowed list, for each deployed tenant.
- **For local development with `AUTH_ENABLED=true`**, the client also needs
  `http://localhost:4000/auth/callback` (Cognito permits plain `http` only for `localhost`), or a
  separate dev app client.
- The sign-in client must be a **confidential client with a secret**, using the Authorization Code
  grant, allowing the `openid` and `email` scopes. It is a different client from the `_API` M2M one.

## Consequences

### Positive

- `AUTH-A01`–`A06`, `A08`, `A09` and `NAV-A10` are met as written, including `nonce` and PKCE.
  `mix nucleus.trace` now reports 8 of 12 `AUTH` and 9 of 10 `NAV` actions covered.
- `auth_failure` is finally wired, and only to callback failures.
- Replacing the identity provider means editing `Nucleus.Auth.Config` and `Nucleus.Auth.OIDC`.
- No token is stored, and the cookie that holds the session is unreadable to its holder.

### Negative

- **Single node, and a restart forgets terminations.** See above; both are stated limits, not bugs.
- **Expiry-deduplication markers are bounded, not permanent.** Full session metadata is compacted at
  max age and the marker is deleted three `max_age` periods later, so memory and the one-minute
  prune scan are bounded by sign-ins in that window. A cookie replayed after deletion produces one
  further `sign_out` audit event (`reason=max_age`), accepted by product decision.
- **The real Hosted UI round-trip is not automated** (`0008`: no browser driver). Everything on
  Nucleus's side of it is tested against a `Req.Test` stub and a generated signing key; the browser's
  redirect to Cognito and back, and the tab's automatic reconnect after a disconnect broadcast, are a
  manual/staging check. Recorded in `test/README.md`.
- **A click in an already-connected tab is served until the expiry broadcast closes the tab.** By
  product decision (`AUTH-A05`), not an oversight.
- **A bad callback replayed by a signed-in user shows the failure page** while their session remains
  valid; a failed callback deliberately does not end a good session.
- **`jose` is a new dependency.** `mix hex.audit` also reports advisories on `mint` (pulled in by
  `req`); those predate this ticket and are untouched by it.

## Alternatives considered

**`ueberauth_cognito`.** Rejected for the reasons above; it fails `AUTH-A02`'s `nonce`/PKCE wording and
cannot be stubbed with `Req.Test`. Dropping `nonce`/PKCE from the requirement, or forking the library,
were the other ways to use it; the first needs its own wiki decision and the second was ruled out.

**`oidcc` / `ueberauth_oidcc`** — certified and IdP-neutral, but the heaviest option, with its own
provider-configuration and HTTP machinery, for one Cognito pool.

**Generic OIDC discovery.** See above: flexibility nobody expects to use, at the cost of a startup
dependency.

**Phoenix.Presence as the activity clock.** See above; kept for `AUTH-A12`.

**An idle clock in the cookie alone.** Cannot be advanced from a socket; a tab active for an hour would
read as idle on its next HTTP request.

**A `handle_event`-level session check.** Explicitly out of scope by product decision under `AUTH-A05`.

**`:uri` in `connect_info` to learn the page on reconnect.** It is the websocket's URL, not the page's.

## References

- `AUTH-S1` (issue #113); absorbs `NAV-A10` from `NAV-S4` (#90) and the `auth_failure` wiring from
  `AUD-S4` (#105)
- `docs/adr/0038-session-based-authentication-no-token-passthrough.md` — the model implemented here
- `docs/adr/0039-tenant-api-service-credential.md` — sign-in requests no API scope and keeps no tokens
- `docs/adr/0005-deferred-authentication.md` — the seam this ADR makes real
- `docs/adr/0006-application-shell-and-live-session-composition.md` — the `on_mount` order `ScopeHook` keeps
- `docs/adr/0004-audit-emission.md` — `sign_in`, `sign_out` and `auth_failure` go through it
- `docs/requirements/Authentication-and-Access.md`, `docs/requirements/Platform-Operations.md`
- Follow-ups: `AUTH-S2` (sign-out through the Hosted UI, `NAV-A09`), `AUTH-A12`–`A14` (active sessions,
  termination, the "session ended" page)
