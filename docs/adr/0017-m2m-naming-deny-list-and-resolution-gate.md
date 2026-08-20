# ADR-0017: M2M Client Naming, Deny-List, and the Resolution Gate

## Status

Accepted — 2026-08-19

Decided on [M2M-S1](https://github.com/dave-bell/nucleus/issues/34). Builds on
`0002-backend-adapter-boundaries.md` (the neutral `Nucleus.Backend.Error` kind
vocabulary), `0009-environment-validation-ladder.md` (`SEC-S1`'s equivalent
gate — the structure this ADR reuses one boundary over), and
`0016-m2m-client-adapter.md` (EN-10's `Nucleus.M2M.Clients` boundary, which
this ticket's gate sits above and which explicitly defers tenant/deny-list
filtering to it).

## Context

Every other M2M action operates on "a client belonging to this tenant."
`M2M-A13` requires a malformed client ID be rejected before any lookup;
`M2M-A14` requires a client outside this tenant's namespace, or one on a
reserved deny-list, be rejected as "not found" — never exposed. Unlike
Secrets, which gates per-environment because the environment arrives on the
URL, M2M has no environment: `TENANT_NAMESPACE` is fixed per deployment, so
the gate here is about the client identifier and the client name, not a
caller-supplied scope.

Four questions were resolved on the issue thread before implementation
started, all `needs-decision` before this ticket, all closed by the time
work began:

1. What suffix set does `M2M_DENY_SUFFIXES` default to — the wiki's config
   reference named "a standard set of reserved suffixes" but enumerated it
   nowhere.
2. How tight should `Nucleus.M2M.ClientId`'s allowlist be — the ticket body's
   own plan considered three widths and left the choice open.
3. Is tenancy the `{tenant}-` prefix or the longer `{tenant}-control-plane-`
   prefix — the shorter one is not collision-safe in a Cognito pool shared
   across tenants.
4. Is the deny-list enforced only at the list/detail gate, or at creation
   too — EN-10's removal of `M2M-A09` (no client-name-uniqueness check)
   means nothing else in the system would catch a reserved name at creation
   time.

## Decision

### The `M2M_DENY_SUFFIXES` default is the prototype's Terraform value

`-labops-ui,-faas-api,-faas-ui,-device_grant,-orange,-nucleus` — hardcoded
into `config/dev.exs` and `config/test.exs`, on the `TENANT_NAMESPACE =
"local"` precedent, so a fresh clone boots with the deny-list exercised
against real values rather than a placeholder. `M2M_DENY_SUFFIXES` moves from
Optional to Required in `Platform-Operations.md`'s config reference, with the
fail-closed and `none`-sentinel behaviour spelled out.

`Nucleus.M2M.DenyList.parse/1` is pure: `nil`, `""`, whitespace-only, or a
value that splits to nothing (`","`, `",,"`) all produce `:unset`.
`suffixes/0` then returns `{:error, %Error{kind: :not_configured}}` — an
absent value is far more likely to be a Terraform template rendering nothing
than a deliberate "allow everything" choice, and a silently empty deny-list
is exactly the failure `M2M-A14` exists to prevent. The literal value
`"none"` (case-insensitive) is the one way to say "deny nothing" on purpose.
Matching is case-insensitive — Nucleus-built names are lowercase by
construction, but a Terraform- or console-created name may not be, and the
fail-safe direction for a deny-list is to match more, not less.

### `Nucleus.M2M.ClientId` uses AWS's own pattern, not a tighter one

`~r/\A[A-Za-z0-9_+]{1,128}\z/`, anchored — AWS's documented `ClientId` shape
(`[\w+]+`, 1–128 characters), not the tighter `[a-z0-9]{1,128}` the ticket's
plan leaned toward, and not the exact `[a-z0-9]{26}` shape of every ID
observed against this pool so far. A well-formed-but-nonexistent ID already
returns `:not_found` from one `describe_client/1` call; guessing the pattern
too tight risks every real client 400ing until a deploy, for a security
property (rejecting hostile shapes) the wider pattern gives up nothing on —
`..`, `/`, `\`, null bytes, whitespace, unicode lookalikes, and
percent-encoding are all still rejected by construction, since none of those
characters are in `[A-Za-z0-9_+]`.

### Tenancy is the full `{tenant}-control-plane-` prefix, not `{tenant}-`

The Cognito pool is shared across tenants today (one Nucleus instance per
tenant, but one pool, per the infra plan). The shorter prefix is not
collision-safe: tenant `acme` would match `acme-corp-nomad`, reading and
offering secret rotation on another tenant's client — the exact defect
`M2M-A14` exists to prevent. `{tenant}-control-plane-` does not have this
problem: `acme-corp-control-plane-X` does not start with
`acme-control-plane-`. Making the shorter prefix safe would require this
deployment to enumerate sibling tenant namespaces, which it has no access to
— `TENANT_NAMESPACE` is its own, singular, per `Platform-Operations.md`.

`M2M-A01`'s wiki wording is amended: "belonging to this tenant" now means
following the full naming convention, not merely starting with the tenant's
short name. A consequence, deliberate: under this prefix, `Nucleus.M2M.DenyList`
is narrower than `M2M-A14`'s prose implies — it can only ever catch a
reserved name that *also* follows the control-plane convention. Five of the
six configured suffixes (`-nucleus`, `-orange`, `-faas-api`, `-faas-ui`,
`-labops-ui`) are reachable as an M2M `purpose` and matter for the creation
guard below; `-device_grant` contains an underscore, which
`Nucleus.M2M.Purpose`'s `[a-z0-9-]+` charset can never produce, so it matters
only for the list/detail gate.

If/when the infrastructure moves to one pool per tenant, this prefix check
becomes redundant but stays harmless — removing it would *widen* the list to
every client in that tenant's own pool, a requirement change, not a cleanup.

### The deny-list is enforced at creation too — new wiki action `M2M-A18`

Without this, an operator can pick purpose `nucleus` (a reserved suffix) and
create `{tenant}-control-plane-{ticket}-nucleus`. EN-10's removal of
`M2M-A09` means there is now no creation-time collision check of any kind to
catch this incidentally — the client would be created with a real secret,
then be invisible in the list and 404 on rotation via this same gate: the
same "created but unreachable" failure `visible?/1` prevents on the read
path, arriving instead through the write path, and worse, since a live
secret would have no recovery route. `Nucleus.M2M.DenyList.denied?/1` is the
predicate this needs, callable directly against `Nucleus.M2M.ClientName.build/2`'s
output before `create_client/2` ever runs. This ticket owns the predicate and
its own reserved-purpose test; #38 (M2M-S5) owns the form-facing 422
rejection and claims `M2M-A18` itself.

### `fetch/2`'s ordering, and the structurally-identical `:not_found` collapse

`Nucleus.M2M.fetch/2` mirrors `Nucleus.Environments.fetch/2`'s ladder:
validate the client ID (zero adapter calls on failure — the load-bearing
test of this ticket, proven with a raising module swapped into the `:m2m`
boundary rather than `LOCAL_FORCE_ERROR`, which is node-global and would be
intercepted by whichever boundary runs first), then check the deny-list
config is readable at all (fail closed, no adapter call on that branch
either), then call `Clients.describe_client/1`, then check `visible?/1`
(tenancy and deny-list together) on the result.

`M2M-A14` requires an out-of-tenant or deny-listed client be "never exposed
here" — step 4's failure manufactures `{:error, %Error{kind: :not_found,
boundary: :m2m, message: "no such client", details: %{client_id:
client_id}}}`, byte-for-byte the same shape `Nucleus.M2M.Clients.Local`
itself returns for a client that genuinely does not exist. A distinct kind
or a distinguishing detail key would itself confirm to the caller that the
ID exists, which is exactly the information the requirement withholds.

### `visible?/1` is the one shared predicate

Used by this module's own step 4 and reserved for M2M-S2's list filter, so a
future list-view fix cannot drift from this gate and leave a client invisible
in the list but still rotatable by URL.

### `ClientId.validate/1` returns `Error.t()` directly, not a bare atom

The ticket's own plan text typed `Nucleus.M2M.ClientId.validate/1` as
`:ok | {:error, atom()}`, matching `TicketId`/`Purpose`. Implemented instead
to return `:ok | {:error, Nucleus.Backend.Error.t()}`, matching
`Nucleus.Environments.validate_name/1`'s precedent. The two form validators
(`TicketId`, `Purpose`) have no boundary concept — they validate a form
field before `ClientName.build/2` ever runs, and M2M-S4's form needs a plain
reason atom to map to per-field copy. `ClientId` exists specifically to gate
the `:m2m` adapter boundary before `fetch/2` calls it, and has exactly one
failure mode (does not match the pattern) rather than several distinct
reasons a form would need to distinguish — returning the same `Error.t()`
shape `fetch/2` needs anyway avoids `fetch/2` having to construct one from a
bare atom on the way out.

## Consequences

### Positive

- `Nucleus.M2M.fetch/2` is the one gate every M2M action mounts through, and
  its zero-adapter-call guarantee is checked structurally (a raising fake),
  not inferred from behaviour — matching ADR-0009's precedent exactly.
- `Nucleus.M2M.DenyList.denied?/1` is safe to call standalone, ahead of
  `Clients.create_client/2`, for M2M-S5's `M2M-A18` rejection — no second
  copy of deny-list logic needs to exist for the write path.
- Seed fixtures (`priv/backends/local_seed.json`) now isolate the prefix
  branch and the deny-list branch of `fetch/2` step 4 individually — a
  conforming-but-denied name and a non-conforming-but-not-denied name each
  exist as their own fixture, so a bug in either branch cannot hide behind
  the other always agreeing.

### Negative

- `Nucleus.M2M.DenyList.denied?/1`'s fail-closed default (`true` when
  `suffixes/0` itself is unconfigured) is currently unreachable from
  `fetch/2`, which always checks `suffixes/0` directly first and returns
  before `visible?/1` is ever called on that branch. It exists only for
  #38's standalone creation-time call, which has no equivalent earlier
  check of its own — a reader tracing `fetch/2` alone would not discover
  why this branch exists.
- The M2M pool's shared-across-tenants shape (Decision 8's premise) is
  itself a limitation this ADR narrows around rather than removes; moving to
  one pool per tenant later makes the prefix check redundant, not wrong, and
  that follow-up is not tracked as an open question here since it depends on
  an infrastructure change outside this ticket's scope.

## Alternatives considered

**A three-character denylist or a tighter, length-exact `ClientId` pattern.**
Rejected for the same reason ADR-0009 rejected a three-sequence denylist for
environment names: an allowlist is strictly the stronger check, and a
length-exact pattern risks a total feature outage on any AWS-side variation
this deployment has not yet observed, for no security benefit over the
wider pattern.

**The shorter `{tenant}-` tenancy prefix.** Rejected — not collision-safe in
a pool shared across tenants; see Decision 8 above.

**Deferring the creation-time deny-list check to whenever #38 happens to
write it, with no shared predicate.** Rejected — `M2M-A09`'s removal (EN-10)
means no other check exists to catch a reserved-purpose creation
incidentally, and a second, independently-written deny-list check in #38
risks drifting from this one exactly the way `visible?/1` exists to prevent
for the read path.

## References

- M2M-S1 (issue #34) — the deciding issue, including
  [Decision 2](https://github.com/dave-bell/nucleus/issues/34#issuecomment-5350433802) (deny-list defaults),
  [Decision 5](https://github.com/dave-bell/nucleus/issues/34#issuecomment-5350434771) (client ID pattern),
  Decision 8 (tenancy prefix), and Decision 9 (`M2M-A18`)
- `docs/adr/0009-environment-validation-ladder.md` — `SEC-S1`'s equivalent
  gate, and the structure this ADR reuses
- `docs/adr/0016-m2m-client-adapter.md` — EN-10's `Nucleus.M2M.Clients`
  boundary, which explicitly defers tenant/deny-list filtering to this gate
- `.opencode/context/project-intelligence/living-notes.md` — the
  `LOCAL_FORCE_ERROR` node-global gotcha this ticket's zero-adapter-call test
  works around the same way `SecretsLiveTest.FailingSecretsStore` does
- Wiki [M2M-Clients](https://github.com/dave-bell/nucleus/wiki/M2M-Clients)
  `M2M-A13`, `M2M-A14`, `M2M-A18`, the API-contract naming convention, and
  the error/edge-case matrix
</content>
