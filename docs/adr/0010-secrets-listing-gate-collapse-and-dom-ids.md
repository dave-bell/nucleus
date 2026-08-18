# ADR-0010: Secrets Listing — Context-Layer Gate Collapse, ARN-Hashed DOM IDs, Boundary-Disambiguated Errors

## Status

Accepted — 2026-08-17

Decided on [SEC-S2](https://github.com/dave-bell/nucleus/issues/10). Builds on
`0009-environment-validation-ladder.md` (the gate this ticket now calls once,
not twice), `0007-secrets-store-adapter.md` (the `:secrets` boundary this
ticket lists from), and `0002-backend-adapter-boundaries.md` (the `kind`/
`boundary` vocabulary this ticket is the first to match on both fields at
once).

## Context

SEC-S1's plan had `SecretsLive.handle_params/3` call
`Nucleus.Environments.fetch/2` directly and keep the resolved
`%Environment{}` in a `resolved_environment` assign that no template ever
read — because listing (this ticket) was still blocked. With both blockers
(`#4`, `#9`) closed, three things the original plan left open or got wrong
needed settling before implementation: how the LiveView calls two backend
boundaries without duplicating the gate, what a stream row's DOM id should
be when the natural key (the secret's `key`) can contain unicode and spaces
the plan never resolved a sanitiser for, and how to tell apart two
same-`kind`, different-boundary errors (`:unavailable` from the environment
gate vs. from the secrets store itself) without collapsing them and
misinforming the user about which system is actually down.

## Decision

### One call to `Nucleus.Secrets.list/2`, not two

`Nucleus.Secrets.list/2` gates through `Environments.fetch/2` internally and
discards the resolved `%Environment{}` — `SecretsLive` calls only this
function. The gate is load-bearing, not defensive: `Store.Local.list_secrets/1`
does `Map.get(buckets, environment, %{})`, so an unvalidated, nonexistent
environment would otherwise render `SEC-A14`'s empty state indistinguishably
from a real, seeded-empty one. Collapsing to one call also removes the now
provably dead `resolved_environment` assign and `scope_token/1` helper —
the whole `%Nucleus.Scope{}` is passed to the context instead, per Phoenix
1.8 scope convention.

### Row DOM ids are a hash of the ARN, not the key

`stream_configure(:secrets, dom_id: &dom_id/1)` where `dom_id/1` is
`"secret-" <> (:crypto.hash(:sha256, ref.arn) |> Base.url_encode64(padding: false))`.
No convention for hashing an item into a DOM id existed anywhere in this
codebase before this ticket — `SecretsLive` is the first LiveView here to
stream a collection at all. The ARN was chosen over the key because it is
unique, stable across renders, and never needs sanitising (unlike the key,
which `SEC-S6` permits to contain unicode, spaces, and dots — an
awkward-for-CSS-selector set with no defined sanitiser in the original
plan). Every row also carries `data-key={ref.key}` so later tickets select
on `[data-key="DATABASE_URL"]` rather than the opaque hash.

### Errors are matched on `{kind, boundary}`, not `kind` alone

`fetch_secrets/2`'s `case` distinguishes `kind: :unavailable, boundary:
:tenant_api` (`#secrets-validation-unavailable`, `SEC-A17`'s concern) from
`kind: :unavailable, boundary: :secrets` (`#secrets-unavailable`, this
ticket's own store outage) — both arrive with the same `kind`, and
collapsing them would tell a user "the environment can't be verified" when
the real problem is the secrets store, or vice versa. `:auth_expired` is
matched regardless of boundary and renders a placeholder (`SEC-S7`'s
concern); every remaining kind (`:already_exists`, `:not_configured`) falls
back to the `:secrets` rendering rather than being left unmatched — the
`case` is exhaustive against `Error.kinds/0` today, which also fixes a
latent bug: SEC-S1's original `case` had no `:auth_expired` clause at all
and would have crashed the LiveView the first time the store or the tenant
API returned it.

### Sort: case-fold key, raw key as tiebreak

`Enum.sort_by(refs, &{String.downcase(&1.key), &1.key})`, in the context
module, not the template. `String.downcase/1` alone is a partial order —
`API_KEY` and `api_key` collide under it, so a stable sort then inherits
their relative order from the store's iteration order, which neither
`Store.Local` (map iteration past 32 keys) nor `Store.Aws`
(`GetParametersByPath` pagination) guarantees. The raw key breaks every
remaining tie because keys are unique within an environment.

## Consequences

### Positive

- Exactly one place (`Nucleus.Secrets.list/2`) can bypass the environment
  gate for a listing request; there is no second call site to audit.
- `SEC-S3`–`SEC-S6` have a written DOM-id contract (`dom_id`/`data-key`)
  instead of four tickets independently guessing a key-sanitisation scheme.
- The `:auth_expired` crash is fixed as a side effect of making the `case`
  exhaustive, not as a separate patch.

### Negative

- `Nucleus.Backend.Faults`' `LOCAL_FORCE_ERROR` is node-global and checked
  by both boundaries' local implementations — since the gate always runs
  first, a global fault is always caught as `boundary: :tenant_api` and the
  `:secrets`-boundary branch is untestable through it. Both new test files
  work around this by swapping in a raising/failing `Nucleus.Secrets.Store`
  implementation instead (the same technique `environments_test.exs` already
  used for `Nucleus.TenantApi`), rather than fixing the fault mechanism
  itself, which stays node-global for every other boundary pair too.
- The row DOM id is opaque (a hash), which is why `data-key` exists — a
  future ticket that selects on the id directly instead of `data-key` will
  work today and become a silent liability if the hash function ever
  changes.

## Alternatives considered

**Keep `Environments.fetch/2` and `Store.list_secrets/1` as two calls in
`SecretsLive` itself.** Rejected — reintroduces the double round trip and
the dead `resolved_environment` assign, and pushes the `{kind, boundary}`
disambiguation into the LiveView instead of the context module owning it
once.

**DOM id from a sanitised key.** Rejected — the original plan's "sanitise
the key, or use an index" left the sanitiser undefined, and `SEC-S6`
permits unicode/spaces/dots in keys with no obvious CSS-safe transform.

**DOM id from list position (index-based).** Rejected — not stable across
the `stream_insert/3` calls `SEC-S4`/`SEC-S5` perform when one row's reveal
or edit state changes.

**ARN as the sort tiebreak instead of the raw key.** Rejected — the ARN's
last path segment is the key itself, so it decides every tie identically to
using the key directly, over a much longer binary.

## References

- SEC-S2 (issue #10) — the deciding issue, including the "Decisions taken at
  start of work" comment this ADR formalises
- `docs/adr/0009-environment-validation-ladder.md` — the gate this ticket
  now calls exactly once
- `docs/adr/0007-secrets-store-adapter.md` — the `:secrets` boundary and its
  `SecretRef` (no `value` field) this ticket lists from
- `docs/adr/0002-backend-adapter-boundaries.md` — the `kind`/`boundary`
  vocabulary this ADR is the first to match on both fields together
- Wiki [Secrets](https://github.com/dave-bell/nucleus/wiki/Secrets)
  `SEC-A01`, `SEC-A14`
