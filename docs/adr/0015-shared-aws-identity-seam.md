# ADR-0015: Shared AWS Identity Seam

## Status

Accepted — 2026-08-19

Decided on [EN-9](https://github.com/dave-bell/nucleus/issues/32). Extracts and generalises
machinery `docs/adr/0007-secrets-store-adapter.md` built for the Secrets boundary alone; the two
role ARNs and the keyed cache this ADR introduces are consumed by EN-10 (issue #33), the Cognito
M2M client.

## Context

`Nucleus.M2M.Clients.Cognito` (EN-10) needs everything `Nucleus.Secrets.Store.Aws` already has and
kept private: `sts:AssumeRole`/`GetCallerIdentity`, a `:persistent_term` credential cache with a
five-minute expiry skew, the STS XML-envelope unwrap, `%AWS.Client{}` construction with the `:plug`
test seam, and AWS error-code classification into `Nucleus.Backend.Error`. Reimplementing it for
Cognito would mean rediscovering facts EN-4 found empirically — the STS envelope shape, the
ISO8601-vs-epoch timestamp asymmetry, treating an unparseable `Expiration` as already-expired — and
would leave two credential caches with two expiry policies against the same STS semantics.

Extracting the machinery into `Nucleus.Aws.*` is mechanical. Two questions the extraction itself
could not answer were raised on the issue and resolved before any code was written:

1. **Which AWS identity reaches the Cognito user pool** — the tenant account (via the existing
   `TENANT_ROLE_ARN`) or the platform account (ambient credentials, no second role)? The pool
   authenticates platform Ops/Support staff today, but the infrastructure is moving the pool to a
   tenant account.
2. **How is AWS region configured** once a second AWS-touching boundary exists — one `AWS_REGION`
   for both, or a second variable, and does one fall back to the other?

## Decision

### Both boundaries assume a role; two independent role ARNs

Neither option the ticket originally offered was taken. `TENANT_ROLE_ARN` continues to serve
`:secrets`, unrenamed and unchanged. EN-10 adds `COGNITO_ROLE_ARN`, set at deploy time to whichever
account holds the user pool — the platform account under today's infrastructure, the tenant
account after the pending migration. A same-account `AssumeRole` is legal AWS IAM and is taken
deliberately: it buys scoped `cognito-idp` permissions the deployment's ambient identity should not
carry directly, and it makes the account question a deploy-time value rather than a code fork that
would need to change again when the infrastructure moves.

The evidence favouring two role ARNs over shared ambient platform credentials: `TENANT_ROLE_ARN` is
documented narrowly, for Parameter Store only; `COGNITO_REGION` is already named as the *base*
region with `SSM_REGION` as an override, implying Cognito and Parameter Store were never assumed to
share one region; the prototype ADR annotates Parameter Store "(cross-account access)" with no such
note on Cognito App Clients; and `OPS-A12` ("one set of Cognito/AWS credentials for that tenant")
forbids runtime tenant switching but does not require the *same* credentials `:secrets` uses.

([Decision](https://github.com/dave-bell/nucleus/issues/32#issuecomment-5346210914))

### The credential cache is keyed on the assume-role request, not the caller

With two role ARNs, the single-slot cache `Nucleus.Secrets.Store.Aws.CredentialCache` used — "one
tenant per deployment, so exactly one slot" — is wrong: a single slot would hand one boundary's
credentials to the other. `Nucleus.Aws.CredentialCache` is keyed on
`{role_arn, external_id, session_name}` — the request that produced the credentials, not which
boundary asked. Keyed on its input, the cache self-collapses: configuring both ARNs identically
produces one slot and one `AssumeRole` cadence; configuring them differently produces two. Keyed on
the boundary it could not do that. Keys stay bounded by configuration (two, today), so
`:persistent_term`'s write-time global scan remains a non-issue at roughly-hourly writes.

`session_name` is part of the key deliberately, not an oversight: `"nucleus-secrets"` already
appears in the tenant's CloudTrail inside the assumed-role session ARN, and collapsing both
boundaries onto one shared name would be an observable change to what the secrets adapter does —
out of scope for a ticket whose only acceptance test is "no diff in the existing suite." `:secrets`
keeps `nucleus-secrets`; EN-10 gets `nucleus-m2m`. The cost is one extra `AssumeRole` per hour in the
same-ARN case, in exchange for exact CloudTrail attribution per boundary.

`CredentialCache.clear/0` becomes `clear/1`, taking the key, and `Nucleus.Aws.Error.classify/3`'s
`ctx` carries `cache_key` alongside `boundary` so an expired-credential-shaped error clears only its
own slot. `clear_all/0` was considered and rejected: it would mean an `ExpiredToken` run on one
boundary churns the other boundary's perfectly good credentials on every request.

([Decision](https://github.com/dave-bell/nucleus/issues/32#issuecomment-5346210914))

### Region is parameterised now; the second variable lands in EN-10

`Nucleus.Aws.Client` and `Nucleus.Aws.Credentials` take `region` as an argument and read no
application env. `AWS_REGION` → `Nucleus.Secrets.Store.Aws[:region]` is untouched by this ticket,
and `config/runtime.exs` is unchanged — this stays a pure refactor with no variable added without a
reader. `COGNITO_REGION`, required at boot with **no fallback to `AWS_REGION`**, lands in EN-10
alongside the wiki amendment that drops `SSM_REGION`.

The requirement's second region variable is right, but its *fallback chain* is not: `SSM_REGION`
falling back to `COGNITO_REGION` would couple the secrets adapter's configuration to Cognito's for
no operational gain, and an implicit fallback is harder to reason about than two variables that must
each be independently set. Adding `COGNITO_REGION` in *this* ticket, with no reader and no
documented relationship to `AWS_REGION`, would have been the "worst of both" — a variable nobody
reads yet, next to an unexplained one nobody uses yet either. One invariant carries forward
unchanged: `build_arn/2` uses the same `region()` that signs the request — an ARN naming a
different region than the call that created it would simply be wrong.

([Decision](https://github.com/dave-bell/nucleus/issues/32#issuecomment-5346214093))

### Shared modules take a spec/ctx, reading no application env

`Nucleus.Aws.Credentials.fetch/1` takes a `spec` map (`boundary`, `role_arn`, `region`,
`external_id`, `session_name`, `http_client_opts`) assembled by each adapter from its own config.
`Nucleus.Aws.Error.classify/3` takes a `ctx` map (`boundary`, `cache_key`, `codes`,
`transport_message`) for the same reason. Neither shared module reads `Application.get_env/2` — the
adapter is the one place that knows its own env-var names (`TENANT_ROLE_ARN` vs. the future
`COGNITO_ROLE_ARN`), and passing everything as data keeps `Nucleus.Aws.*` boundary-neutral rather
than accumulating `if boundary == :secrets` branches as EN-10 adds a second real caller.

`boundary` threading through both specs and ctx has two concrete effects it exists to have: the
request-ID log lines inside `Nucleus.Aws.Credentials` say `"#{boundary} aws assume_role ..."`
instead of the hardcoded `"secrets aws ..."` the extracted code came with, so `:m2m`'s STS calls do
not claim to be `:secrets`'s; and the returned `Nucleus.Backend.Error.boundary` field, which callers
already use to distinguish two boundaries' `:unavailable` errors, keeps working once a second
boundary produces one.

SSM's `ParameterNotFound`/`ParameterAlreadyExists` codes stay in `Nucleus.Secrets.Store.Aws`,
passed into `classify/3` via `ctx.codes` — a plain `%{String.t() => Error.kind()}` map consulted
*before* the generic classification rules. Cognito's equivalent codes (different strings entirely)
will do the same from EN-10 without either adapter's codes shadowing the other's, and without the
shared module needing to know either adapter's vocabulary.

## Consequences

### Positive

- `Nucleus.M2M.Clients.Cognito` (EN-10) starts with a working, tested credential/error seam and
  makes no new architectural decision about how to reach AWS — only which role ARN and region to
  configure.
- The keyed cache means configuring `COGNITO_ROLE_ARN` identically to `TENANT_ROLE_ARN` (the
  same-account case, true under today's infrastructure) costs nothing extra beyond one additional
  `AssumeRole` call per hour; no code path forks on whether the two ARNs happen to match.
- `error.boundary` and the request-ID log prefix now generalise to any future third boundary that
  assumes a role, not just the two named here.

### Negative

- **Two independent role ARNs are two things to get wrong at deploy time**, where the previous
  shape had one. A deployment that sets `COGNITO_ROLE_ARN` to the wrong account produces an
  `AccessDenied`-shaped `Nucleus.Backend.Error` at the M2M boundary specifically — this ADR does not
  add any boot-time cross-check between the two ARNs.
- **The deployment's ambient AWS identity must now be trusted by two roles' trust policies**,
  same-account today and cross-account after the pending Cognito infrastructure migration. This is
  Terraform/ops-doc work, not code, and is explicitly deferred to EN-10 — see `living-notes.md`'s
  existing ambient-AWS-identity debt item, which this ADR does not resolve, only adds to.
- **`nucleus-secrets` and `nucleus-m2m` sharing a role ARN still doubles `AssumeRole` traffic**
  relative to a hypothetical single shared session name, which was rejected specifically to keep
  CloudTrail attribution exact per boundary. The cost is accepted, not eliminated.

## Alternatives considered

**Ambient platform credentials for Cognito, no second role ARN (the ticket's own fallback
option).** Rejected. The evidence — `TENANT_ROLE_ARN`'s narrow documented purpose, the existing
`COGNITO_REGION`/`SSM_REGION` split, the prototype ADR's cross-account annotation on Parameter Store
only — favours a role-based boundary for Cognito too, and hardcoding either account (platform now,
tenant after the migration) would mean the code being wrong for one of the two releases.

**A single credential-cache slot, boundary-agnostic (the ticket's original plan).** Rejected once
two independent role ARNs were decided — a single slot cannot hold two boundaries' credentials at
once without one overwriting the other.

**`SSM_REGION` falling back to `COGNITO_REGION` (the requirement's literal wiki text).** Rejected.
Two independently-required region variables, with no fallback, keep each boundary's configuration
legible on its own rather than coupled through an implicit default.

**Renaming `TENANT_ROLE_ARN` to `SSM_ROLE_ARN` for symmetry with `COGNITO_ROLE_ARN`.** Rejected —
a breaking config change for already-deployed instances, for a cosmetic gain. The wiki's purpose
text is amended instead, in EN-10.

## References

- EN-9 — [issue #32](https://github.com/dave-bell/nucleus/issues/32), the deciding issue, including
  the full implementation plan and both resolved decisions
- `docs/adr/0007-secrets-store-adapter.md` — the STS/credential/error machinery this ADR extracts
  and generalises; every empirically-discovered fact recorded there (the XML envelope, the
  timestamp asymmetry, ambient Nucleus identity) still holds and now lives in `Nucleus.Aws.*`
- `docs/adr/0002-backend-adapter-boundaries.md` — the six neutral `Nucleus.Backend.Error` kinds and
  the `error.boundary` discriminator this ADR's `ctx`/`boundary` threading keeps usable
- EN-10 — [issue #33](https://github.com/dave-bell/nucleus/issues/33), which consumes
  `Nucleus.Aws.*` for `Nucleus.M2M.Clients.Cognito` and inherits `COGNITO_ROLE_ARN`,
  `COGNITO_REGION`, the `nucleus-m2m` session name, and the wiki config-reference amendment
- `docs/requirements/Platform-Operations.md` config reference — `TENANT_ROLE_ARN`, `COGNITO_REGION`,
  `SSM_REGION`, amended by EN-10 rather than this ticket
- `.opencode/context/project-intelligence/living-notes.md` — the ambient-AWS-identity technical debt
  item this ADR's "deployment identity trusted by two roles" consequence adds to, not resolves
