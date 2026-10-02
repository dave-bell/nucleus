# ADR-0039: A Service Credential for the Tenant API

## Status

Accepted — 2026-10-02

Decided on [EN-13](https://github.com/dave-bell/nucleus/issues/112), in
[this comment](https://github.com/dave-bell/nucleus/issues/112#issuecomment-5962309646)
and its [plan revision](https://github.com/dave-bell/nucleus/issues/112#issuecomment-5963244413).
Builds on `0038-session-based-authentication-no-token-passthrough.md`, whose last open item
it closes, and supersedes the `token` field described in
`0005-deferred-authentication.md`.

## Context

`0038` dropped token passthrough: Nucleus keeps no user token after sign-in, so every
backend is reached with a service credential of its own. Parameter Store already was
(an assumed AWS role, `0002`/`0015`). The Tenant API was the one boundary left, and
`0038` named its credential type as the only thing it did not settle.

Until this ticket the code still had the shape `0005` built for passthrough:
`Nucleus.Scope.token`, a token argument on every `Nucleus.TenantApi` call, threaded
through `Environments.fetch/2`, `Secrets.*` and three LiveViews, and a conditional
`Authorization: Bearer` header in `Nucleus.TenantApi.Http`. All of it carried `nil`.

The Tenant API expects a Cognito access token, so static keys and SigV4 were never
real options: neither is accepted by it.

## Decision

### Nucleus calls the Tenant API with its own Cognito M2M token

The client-credentials grant, with a Nucleus-only M2M app client created by Terraform at
deploy time. It is separate from the sign-in client (`COGNITO_CLIENT_ID`) and from the
M2M clients tenants create for themselves (`Nucleus.M2M.Clients`, EN-10). Calls are
attributed to the Nucleus service, not to the signed-in user.

Configuration, named to match PLAT-faas: `COGNITO_CLIENT_ID_API`,
`COGNITO_CLIENT_SECRET_API`, `COGNITO_SCOPE`, and `COGNITO_DOMAIN` — a **bare host**, no
scheme, so the token endpoint is `https://{COGNITO_DOMAIN}/oauth2/token`.
`TENANT_API_BASE_URL` moves from a `:not_configured` error on the first call to a boot
check.

### The facade fetches the token; the implementations still take it

Callers of `Nucleus.TenantApi` pass nothing auth-related: `list_environments/1` becomes
`list_environments/0`. The **facade** asks `Nucleus.TenantApi.ServiceToken` for a token and
hands it to `impl().list_environments(token)`. The behaviour callback is unchanged, so
`Http` (sends it as `Authorization: Bearer`), `Local` (ignores it) and any test double are
untouched, and `Http`'s tests can still pass any value and stub the request.

This diverges from the issue's plan, which had every layer drop the argument and `Http`
fetch its own token. The facade is the only place that can also invalidate the cached
token when the API rejects it, and it keeps the implementations free of a dependency on a
cache process.

A token that cannot be fetched is returned as that error and **no request is made**. A
tenant API `:auth_expired` (401 or 403) makes the facade invalidate the token it used and
return the error unchanged. Nothing retries here: the single automatic retry is
`SEC-S7`'s (#15), at the context layer, and the invalidation is what lets that retry fetch
a fresh token instead of resending the rejected one. Until it lands, a rejected cached
token fails one call and the next call succeeds.

### The token source is a boundary of its own: `:service_token`

Dev and test must run the same code path as production, without a Cognito client. So the
source of the token is a `Nucleus.Backend` boundary (`SERVICE_TOKEN_BACKEND`, `real` or
`local`), like the other five. `Nucleus.TenantApi.ServiceToken` is a supervised cache that
knows nothing about Cognito; its driver is either
`Nucleus.TenantApi.ServiceToken.Cognito` (the grant above) or `.Local` (a canned token, good
for an hour). The facade has no mode check.

The cache holds a token until `expires_in` minus 60 seconds, shares one fetch between
concurrent callers (run in `Nucleus.TaskSupervisor`, so a slow or crashing driver cannot wedge
the cache), and never caches an error. The real driver maps a token-endpoint 400 or 401 to
`:auth_expired` and a 5xx, transport failure or malformed body to `:unavailable`; it uses
`retry: false`, `redirect: false` and separate timeouts, and logs only a status and a request
id — never the secret, the token or the body.

`invalidate/2` takes the token that was *rejected* and drops the cache only if it still holds
that one. Two callers that both get a 401 on the same old token cannot discard the fresh
token one of them just fetched; an unconditional invalidate would.

`.Local` deliberately skips `Nucleus.Backend.Faults`: `LOCAL_FORCE_ERROR` is node-wide, so
applying it here would make a fault aimed at `:tenant_api` surface as a `:service_token`
error and hide the boundary under test.

### Boot checks: two gates

- `TENANT_API_BASE_URL` is required when `:tenant_api` runs its real implementation.
- `COGNITO_DOMAIN`, `COGNITO_CLIENT_ID_API`, `COGNITO_CLIENT_SECRET_API` and `COGNITO_SCOPE`
  are required when `:service_token` runs its real implementation. Blank counts as missing.

They are separate because the two boundaries are independent. `tenant_api` real with
`service_token` local would send a canned token to the real API; the existing boot warning
for local boundaries names it, and that is the only guard.

### `health_check` stays anonymous

`health_check/0` has no token and sends none, so a 401 or 403 still counts as *reachable*.
The decision comment said a rejection should count as unhealthy, because Nucleus now always
sends a credential. That is not implemented: a rejected credential is reported by
`list_environments`, as `:auth_expired`, and reachability is what a probe is for. Revisit
if a credential-aware readiness check is wanted.

### `Nucleus.Scope.token` and the plumbing are deleted

The field, `AssignScope`'s `%{scope | token: nil}` line, and every call site that forwarded a
token. `Secrets.*` keep their scope argument, which audit records need; `Environments.fetch`
drops to `fetch/1`, since it never used anything else from the scope.

## Consequences

### Positive

- Nothing in the codebase reads a user token, and the session cookie's `Scope` cannot carry one.
- Dev, test and production share one code path for the token; the local driver is the only
  difference.
- Token expiry is invisible to the user once `SEC-S7`'s retry lands, and costs one failed
  call until then.
- `0038`'s "known-dead code stays until EN-13" note is closed.

### Negative

- **The Tenant API attributes calls to Nucleus, not to the user.** Fine while Nucleus only
  reads; it must be revisited before Nucleus first *writes* to the Tenant API. Recorded as
  an open question in `living-notes.md`. A lead: PLAT-faas got an unusable user access token
  because sign-in requested only `openid` at `/oauth2/authorize`; requesting the API scope
  there probably yields a usable one. `#113` (AUTH-S1) is unchanged — sign-in still requests
  no API scope and keeps no tokens.
- **A sixth boundary and a sixth `*_BACKEND` variable.** `Nucleus.Backend`'s "auth is never
  swappable" note needed a sentence: `:service_token` is Nucleus's own credential, not
  authentication, and says nothing about who the user is.
- **`config/runtime.exs` gates cannot trust `Application.get_env/3`.** `config/3` calls in that
  file are not visible to `get_env` until the file has been evaluated, so the existing
  `:secrets`, `:m2m` and Nomad gates miss a `*_BACKEND=real` override and still demand their
  variables under `*_BACKEND=local`. The two new gates read the override variable themselves.
  The older gates are unchanged here.
- **The 401/403 handling lives in the facade, not `Http`.** A test of the "one request,
  invalidate, refetch" behaviour therefore goes through `Nucleus.TenantApi`, with `Http`
  behind a `Req.Test` plug.

## Alternatives considered

**A static API key.** Rejected: the Tenant API accepts a Cognito token. It would also need a
rotation story and somewhere to live that is not Parameter Store, which is the tenant's store.

**IAM/SigV4**, matching Parameter Store. Rejected: the Tenant API is not AWS-fronted with IAM
auth.

**Every layer drops the token argument, `Http` fetches its own.** The issue's original plan.
Rejected in favour of the facade owning the fetch, for the invalidation reason above.

**Cache the token in the facade's caller, or in `:persistent_term`** as `Nucleus.Aws.CredentialCache`
does. Rejected: single-flight fetching needs a process to serialise on, and a stampede of
concurrent mounts on an expired token is the normal case, not an edge.

**A per-call mode check in the facade, returning `nil` for `Local`.** Rejected: dev would no
longer exercise the production path, and every test double would need the same special case.

**Copy PLAT-faas's `Faas.Authentication.access_token/0` exactly.** Rejected in part: it caches
a failed fetch as `{:ok, "nil"}` and ignores `expires_in` for a fixed lifetime. The approach
is the same; those two behaviours are not.

## References

- Issue #112 (`EN-13`) and its decision comment and plan revision
- `docs/adr/0038-session-based-authentication-no-token-passthrough.md` — the decision this
  completes
- `docs/adr/0005-deferred-authentication.md` — the `token` field this supersedes
- `docs/adr/0002-backend-adapter-boundaries.md` — the `:auth_expired` kind and the service-credential
  precedent
- `docs/adr/0015-shared-aws-identity-seam.md` — the credential-cache precedent
- `docs/requirements/Platform-Operations.md`, `docs/requirements/Authentication-and-Access.md`
- Issue #15 (`SEC-S7`) — the single context-layer retry this invalidation enables
- Issue #113 (`AUTH-S1`) — sign-in; unchanged by this decision
