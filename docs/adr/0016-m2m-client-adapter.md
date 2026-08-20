# ADR-0016: M2M Client Adapter

## Status

Accepted — 2026-08-19

Decided on [EN-10](https://github.com/dave-bell/nucleus/issues/33). Builds on
`0002-backend-adapter-boundaries.md` (behaviour/real-local shape),
`0003-shared-local-backend-seed.md` (`Nucleus.Backend.Seed`),
`0007-secrets-store-adapter.md` (the `aws` package and credential-cache
precedent this extends), and `0015-shared-aws-identity-seam.md` (the shared
`Nucleus.Aws.*` seam this adapter consumes without adding to it).

## Context

The `:m2m` boundary is the Cognito App Clients analogue of `:secrets`'
Parameter Store boundary — EN-3/EN-4's adapter pattern extended to a second
AWS-touching boundary now that EN-9 generalised the credential/error
machinery into `Nucleus.Aws.*`. Three decisions were resolved on the issue
thread before implementation — the OAuth scope, the access token validity,
and whether to accept N+1 on listing — each already recorded as its own
issue comment per `ticket-decisions.md`; this ADR is their
implementation-time record, not a restatement of their rationale (see the
issue for that). Implementation itself surfaced a fourth, unplanned
correction: the ticket's own design for `M2M-A09` (duplicate-client
rejection) rested on a false premise about the Cognito API, discovered only
by checking AWS's own API reference directly rather than trusting the
vendored SDK's documentation-only typespecs.

## Decision

### Three-way struct split, secret dropped at the adapter's edge

`Nucleus.M2M.Client` (list row), `ClientDetail` (describe), `ClientCredentials`
(create/rotate only, `@derive {Inspect, except: [:client_secret]}`). Neither
`Client` nor `ClientDetail` has a field for the secret — the same structural
defence `Nucleus.Secrets.SecretRef` gives `SEC-A01`. `Cognito.to_detail/1`
never references `"ClientSecret"` at all, rather than building an
intermediate map from the full Cognito response and stripping the key
afterward — there is no code path where a name bound to both the secret and
the rest of the client's attributes exists.

### Derived OAuth scope, no new config variable

`"#{Nucleus.Scope.tenant_namespace()}/api"`. Accepted, not the ticket's own
recommendation of a new `M2M_CLIENT_SCOPE` variable —
`CreateUserPoolClient` itself rejects a scope absent from the pool
(`ScopeDoesNotExistException`, mapped to `:not_configured`), so the
fail-fast property the alternative was chosen for holds without a second
config surface. New coupling: the pool's resource-server identifier must
equal `TENANT_NAMESPACE` exactly, documented in `Platform-Operations.md`.

([Decision](https://github.com/dave-bell/nucleus/issues/33#issuecomment-5349941399))

### Operator-chosen token validity, 5–60 minutes

Not a fixed module constant. Cognito has no pool-level default to inherit —
`AccessTokenValidity`/`TokenValidityUnits` exist only on the client, never
the pool, in the pinned `aws` dependency's generated types.
`ClientDetail.token_validity_seconds` stores seconds, not minutes —
lossless for a client this feature did not create (Terraform or the
console can set a validity Nucleus's own 5–60-minute range would truncate).
`create_client/2`'s own input unit is minutes, the operator's unit;
`Cognito` sets both `AccessTokenValidity` and `TokenValidityUnits` on every
client it creates so the value is never ambiguous on read-back. A missing
`AccessTokenValidity` on a client this feature did not create falls back to
3600 seconds — Cognito's own undocumented-but-real pool default — rather
than crashing.

([Decision](https://github.com/dave-bell/nucleus/issues/33#issuecomment-5349942648))

### Bounded fan-out for listing, degrade-not-fail per row

`ListUserPoolClients` returns no creation date at all
(`user_pool_client_description` is `ClientId`/`ClientName`/`UserPoolId`
only), so `list_clients/0` fans out one `DescribeUserPoolClient` per client
via `Task.async_stream(max_concurrency: 10, timeout: :infinity)`. A
per-client describe failure yields `created_date: nil, created_date_error:
kind` for that one row; only a failure of the `ListUserPoolClients` call
itself fails the whole operation. `Client` gained the `created_date_error`
field for this; `created_date` and `created_date_error` are never both
non-nil.

([Decision](https://github.com/dave-bell/nucleus/issues/33#issuecomment-5349943455))

### `M2M-A09` removed — Cognito does not enforce client-name uniqueness

Discovered during implementation, not decided on the issue beforehand. The
ticket's plan assumed `CreateUserPoolClient` rejects a duplicate
`ClientName`, which is what would have made `M2M-A09`'s rejection
race-safe, and explicitly ruled out the only fallback (list-then-create) as
racy. Verified against AWS's own `CreateUserPoolClient` API reference
(`docs.aws.amazon.com/cognito-user-identity-pools/...`), not just the
vendored `aws` dependency's documentation-only typespecs (which show the
same absence): `ClientName`'s only documented constraint is length and a
character pattern, and the operation's full Errors list
(`FeatureUnavailableInTierException`, `InternalErrorException`,
`InvalidOAuthFlowException`, `InvalidParameterException`,
`LimitExceededException`, `NotAuthorizedException`,
`OperationNotEnabledException`, `ResourceNotFoundException`,
`ScopeDoesNotExistException`, `TooManyRequestsException`) contains nothing
duplicate-name-shaped. `duplicate_provider_exception()` exists in `deps/aws`
but belongs to the unrelated `CreateIdentityProvider` operation.

`create_client/2` (`Cognito` and `Local`) therefore always creates, matching
Cognito's real behaviour — `ClientId` (auto-generated) is the identifier
that actually disambiguates two same-named clients, and it is already
required on `M2M-A01`'s list. `M2M-Clients.md`'s `M2M-A09` is removed, not
reimplemented, along with the `409` status on the create endpoint and the
corresponding error/edge-case-matrix row; `M2M-A01` gained a note that
`client_id`, not `client_name`, is the real identifier.

([Decision](https://github.com/dave-bell/nucleus/issues/33#issuecomment-5350191153))

## Consequences

### Positive

- `Nucleus.M2M.Clients.Cognito` starts with a working, tested credential/error
  seam from EN-9 and makes no new AWS-access decision of its own — only
  Cognito's own error-code map (`ResourceNotFoundException`,
  `ScopeDoesNotExistException`) is adapter-specific.
- `create_client/2` is simpler than planned: no duplicate-name branch in
  either implementation, no list-then-create race to reason about, and one
  fewer `Nucleus.Backend.Error` kind this boundary needs to produce
  correctly under concurrency.
- `Nucleus.M2M.Clients.Local` genuinely models Cognito's two-secret rotation
  window (a list per client, delete-oldest-if-two, append), so `M2M-S6`'s
  "valid after one rotation, gone after two" assertions are meaningful
  against the local implementation, not vacuous.

### Negative

- **Two tickets already planned around `M2M-A09` need a fresh pass before
  implementation**: #37 (M2M-S4) deferred its own duplicate-name UX
  affordance to #38, and #38 (M2M-S5) built roughly half its plan — audit
  copy, form error handling, and its own test plan — around a server-side
  rejection that no longer exists. Both are back-referenced on the deciding
  comment; neither was actually implemented against the old plan, so no code
  needs undoing, only re-planning.
- **A tenant can end up with two (or more) app clients sharing a display
  name**, indistinguishable to a human operator except by `client_id` and
  creation date. This is Cognito's real behaviour, not a Nucleus gap, but it
  is a UX surface M2M-S2/S3 (#35, #36) should keep in mind when rendering the
  list and detail views.
- **The vendored `aws` dependency's generated typespecs are not reliable
  evidence for API-level constraints that aren't type shapes** — `aws`'s
  documentation-only typespecs and AWS's own API reference agreed here, but
  only the latter was authoritative. `docs/adr/0007-secrets-store-adapter.md`
  already flagged this for response *shapes*; this ADR extends the same
  caution to a request parameter's *semantic* constraints.

## Alternatives considered

**Reimplement `M2M-A09` as list-then-create.** Rejected — this is exactly the
race the ticket's own plan ruled out, and rejecting it was correct; the
premise that made a race-safe alternative possible was wrong, not the
reasoning against the racy one.

**Add an application-level uniqueness check (e.g., a per-tenant name index).**
Rejected without serious consideration — Nucleus holds no data of its own
(`docs/adr/0001-no-local-datastore.md`), and a check backed by nothing
durable would not even be race-safe across two Nucleus processes, let alone
against Terraform or the AWS console creating a client directly.

**Keep `M2M-A09` as a purely advisory, client-side check (compare against
the loaded list before submitting).** Not rejected — this is still available
to M2M-S4 (#37) as a UX affordance, same as the ticket's plan already
allowed for the pre-check. What is rejected is treating it as *enforcement*;
it was never going to be race-safe either way.

## References

- EN-10 — [issue #33](https://github.com/dave-bell/nucleus/issues/33), the
  deciding issue, including the full implementation plan and all four
  resolved decisions
- `docs/adr/0002-backend-adapter-boundaries.md` — the behaviour/real-local
  shape and neutral error kinds this implementation fills in
- `docs/adr/0003-shared-local-backend-seed.md` — `Nucleus.Backend.Seed`, read
  and mutated directly by `Nucleus.M2M.Clients.Local`
- `docs/adr/0007-secrets-store-adapter.md` — the `aws`-package and
  credential-cache precedent this extends to a second AWS boundary
- `docs/adr/0015-shared-aws-identity-seam.md` — `Nucleus.Aws.Credentials`/
  `Nucleus.Aws.Error`, consumed here unmodified via `COGNITO_ROLE_ARN`/
  `COGNITO_REGION` and session name `nucleus-m2m`
- `docs/requirements/M2M-Clients.md` — amended in this ticket's PR: `M2M-A09`
  removed, `M2M-A01` gains the `client_id`-is-the-identifier note
- #37 (M2M-S4), #38 (M2M-S5) — back-referenced; both built part of their plan
  on the now-removed `M2M-A09`
