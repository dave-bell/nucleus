# ADR-0007: Secrets Store Adapter

## Status

Accepted — 2026-08-12

Decided on [EN-4](https://github.com/dave-bell/nucleus/issues/4). Builds on
`0002-backend-adapter-boundaries.md` (behaviour/real-local shape) and
`0003-shared-local-backend-seed.md` (`Nucleus.Backend.Seed`).

## Context

The Secrets boundary reads and writes secret material in the tenant's own
AWS account via SSM Parameter Store, reached by assuming a scoped
cross-account role — issue #4 calls it "the highest-risk surface in the
application." Two decisions were explicitly left open by
`0002-backend-adapter-boundaries.md`: the Parameter Store path pattern, and
how Nucleus talks to AWS at all. Both were resolved on the issue thread
before implementation; a third shape (local state ownership) was resolved
twice, reversing once; and implementation itself surfaced two corrections
the issue's plan could not have anticipated from documentation alone.

## Decision

### Parameter Store path pattern

```
/{cluster}/deployments/{deployment}/faas/functions/{environment}/{key}
```

`{cluster}`/`{deployment}` are deploy-time configuration (`CLUSTER_NAME`/
`DEPLOYMENT_NAME`), never derived from an API call. `{environment}` is an
arbitrary bucket that exists directly in Parameter Store — a real Labbit
environment short name, or the literal `shared` — and is deliberately **not**
validated against, or sourced from, `Nucleus.TenantApi`. This boundary is
pure CRUD over whatever exists under the cluster/deployment prefix, decoupled
from the tenant API's environment list. `Nucleus.Secrets.Path.build/2` is the
sole construction site.

SSM has no folder-listing API, so `list_environments/0` and
`list_all_secrets/0` — new callbacks added ahead of EN-7's discovery/
tenant-wide surfaces — share one recursive `GetParametersByPath(Recursive:
true)` walk over the cluster/deployment prefix, parsed into
`{bucket, key}` pairs, rather than one call per bucket.

([Decision](https://github.com/dave-bell/nucleus/issues/4#issuecomment-5261101492))

### AWS access via the `aws` package, not `ex_aws`

`Nucleus.Secrets.Store.Aws` calls `AWS.STS.assume_role/2`,
`AWS.STS.get_caller_identity/2`, `AWS.SSM.get_parameters_by_path/2`,
`get_parameter/2`, and `put_parameter/2` against an `%AWS.Client{}`, rather
than hand-signing requests with `:aws_signature` directly or using
`ex_aws`/`ex_aws_ssm`/`ex_aws_sts` (stale, and in `ex_aws_ssm`'s case an
unofficial fork). `aws` is code-generated from the AWS SDK Go v2 models —
correct parameter casing for all five calls — and is built on the same
`:aws_signature` foundation the boundary ADR already named, not a different
one. It also ships `AWS.CognitoIdentityProvider` already, which the
Out-of-scope Cognito boundary will reuse without a second dependency
decision.

`Nucleus.Aws.ReqHttpClient` implements `AWS.HTTPClient` against `Req` instead
of `aws`'s bundled Hackney/Finch adapters, per `AGENTS.md`, and is
boundary-agnostic for reuse by that future Cognito implementation.

([Decision](https://github.com/dave-bell/nucleus/issues/4#issuecomment-5261101610))

### Credential caching via `:persistent_term`

Assumed-role credentials are cached in `:persistent_term`, not a supervised
`Agent` — one of the two options the issue's plan itself offered. Credentials
are written roughly hourly and read on every call; a crash loses nothing a
re-`assume_role` would not recover, so the read-heavy/write-rare profile
`:persistent_term` is suited to outweighs the process-based approach used
elsewhere in this codebase for actually-mutable state.

### No dedicated local-state `Agent`

The issue's plan called for a supervised `Agent` holding local secret state.
That was decided twice on the issue thread, reversing once:

1. First, keep the `Agent`; EN-3's ETS-backed seed owner would serve as a
   read-only source the `Agent` initialised from
   ([Decision](https://github.com/dave-bell/nucleus/issues/4#issuecomment-5247423164)).
2. Then reversed once EN-3 built `Nucleus.Backend.Seed` as a
   boundary-neutral **mutable** `Agent` with its own read/write API: a
   second mutable-state process would have nothing left to do
   ([resolution](https://github.com/dave-bell/nucleus/issues/4#issuecomment-5255999387)).

`Nucleus.Secrets.Store.Local` reads and mutates its `secrets` section
through `Nucleus.Backend.Seed` directly, enforcing the same
`:already_exists`/`:not_found` rules the AWS implementation enforces against
real Parameter Store responses.

### Corrections discovered during implementation, not by plan

Two things the issue's plan could not have specified from documentation
alone, both recorded in `aws.ex`'s module/function docs at the point they
matter, not only here:

- **STS's decoded body is the full operation envelope, not a flat map.**
  The plan assumed `body["Credentials"]`/`body["Account"]`, matching `aws`'s
  generated typespecs. Live-testing against `AWS.XML.decode!/2` showed STS,
  as a query/XML-protocol service, actually nests results under
  `body["AssumeRoleResponse"]["AssumeRoleResult"]["Credentials"]` and the
  `GetCallerIdentity` equivalent. `unwrap_result/3` unwraps this explicitly.
  Relatedly, `Credentials.Expiration` is an ISO 8601 string, not the epoch
  integer the typespec implies — SSM's `LastModifiedDate` genuinely is an
  epoch integer, so two separate parsing functions exist rather than one.
- **Nucleus's own AWS identity is ambient, not a new config surface.** The
  issue specified the *target* role (`TENANT_ROLE_ARN`) but not what identity
  Nucleus itself assumes it from. `AWS.Client.create/0,1` reads flat
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` env vars
  with no IMDS/ECS-metadata chain — treated as standard ambient AWS SDK
  variables the deployment environment already provides, not a
  Nucleus-specific addition. Missing values return
  `{:error, %Error{kind: :not_configured}}`, never a crash.

`Nucleus.Secrets.Path.configured?/0` was added, not in the plan, so a missing
`CLUSTER_NAME`/`DEPLOYMENT_NAME` surfaces through the same
`:not_configured` path as a missing role/region, rather than the raise
`build/2` gives a genuine deployment mistake.

## Consequences

### Positive

- The path-construction, listing, and error-mapping decisions all live in
  one place each (`Nucleus.Secrets.Path`, one recursive walk, `aws.ex`'s
  mapping table), so a future resource kind under
  `/{cluster}/deployments/{deployment}/` extends rather than duplicates them.
- `Nucleus.Aws.ReqHttpClient` is already boundary-agnostic, so the Cognito
  boundary named in this issue's Out-of-scope section starts with no new
  HTTP-adapter or dependency decision.
- `Nucleus.Secrets.Store.Local` and `.Aws` enforce identical
  `:already_exists`/`:not_found` semantics, verified by the shared
  `NucleusTest.SecretsStoreContract` module run against both.

### Negative

- **The environment bucket is unvalidated against any authoritative list.**
  Any string is a legitimate Parameter Store bucket; existence-checking a
  environment name against `Nucleus.TenantApi` is explicitly not this
  boundary's job. `SEC-S1` cannot lean on this boundary for that validation
  and must do it independently.
- **`aws`'s generated typespecs are not reliable documentation for STS
  response shapes.** `unwrap_result/3`'s hand-verified unwrapping is now the
  authority; a future AWS SDK version bump should re-verify against a live
  call, not trust the typespec.
- **Nucleus's AWS credentials are entirely ambient.** There is no
  Nucleus-specific config to inspect if the wrong identity is picked up in a
  given environment — a deployment debugging an unexpected `AssumeRole`
  failure must look at the standard AWS SDK environment variables, which
  this codebase does not name or validate anywhere itself.

## Alternatives considered

**Hand-signing SSM/STS requests with `:aws_signature` directly.** Rejected.
`aws` already builds on the same signer with generated, model-accurate
request/response handling — hand-signing would rebuild what `aws` gives for
free while reintroducing the category of casing/shape bugs generation
avoids.

**`ex_aws` + `ex_aws_ssm`/`ex_aws_sts`.** Rejected — both are stale
(2019/2021), and `ex_aws_ssm` is an unofficial fork outside the `ex_aws`
org. No Cognito User Pools package exists in that ecosystem at all.

**A supervised `Agent` for local secret state, as originally planned.**
Rejected on the second pass — see "No dedicated local-state `Agent`" above.
`Nucleus.Backend.Seed` already provides mutable, process-lifetime storage;
a second such process duplicates it for no gain.

**Validating `{environment}` against `Nucleus.TenantApi` before building a
path.** Rejected. Coupling this boundary to the tenant API's environment
list would contradict the "pure CRUD over whatever exists" design and break
the `shared` bucket, which has no tenant-API equivalent at all.

## References

- EN-4 — the deciding issue, including the full implementation plan and both
  resolved decisions
- `docs/adr/0002-backend-adapter-boundaries.md` — the behaviour/real-local
  shape and neutral error kinds this implementation fills in
- `docs/adr/0003-shared-local-backend-seed.md` — `Nucleus.Backend.Seed`, read
  and mutated directly by `Nucleus.Secrets.Store.Local`
- Wiki [Secrets](https://github.com/dave-bell/nucleus/wiki/Secrets) — the
  "no delete operation" contract this boundary honours; no delete callback
  exists anywhere in `Nucleus.Secrets.Store`
- `AGENTS.md` — `Req`-only HTTP guidance, satisfied via
  `Nucleus.Aws.ReqHttpClient`
- EN-7 (issue #7) — the discovery/tenant-wide surfaces `list_environments/0`/
  `list_all_secrets/0` were added ahead of
- EN-8 (issue #8) — the contract test harness whose shared-assertion pattern
  (`NucleusTest.SecretsStoreContract`) this implementation's tests already
  use ahead of that ticket landing
