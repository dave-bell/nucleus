# ADR-0009: Environment Resolution and Fail-Closed Validation Ladder

## Status

Accepted — 2026-08-14

Decided on [SEC-S1](https://github.com/dave-bell/nucleus/issues/9). Builds on
`0002-backend-adapter-boundaries.md` (behaviour/real-local shape, neutral
error kinds) and `0006-application-shell-and-live-session-composition.md`
(the placeholder `SecretsLive` this ticket replaces). Confirms the boundary
line `0007-secrets-store-adapter.md` drew: `Nucleus.Secrets.Store` does not
validate `{environment}` against `Nucleus.TenantApi`, so this ladder is the
only place that validation happens.

## Context

Every Secrets action's precondition is "a valid environment for this
tenant" (`SEC-A01` onward), and a caller-supplied environment name reaches
`Nucleus.Secrets.Path.build/2` — which does no sanitisation of its own — the
moment any of those actions run. `SEC-A15`–`A17` are the gate: reject a
path-traversal name before any lookup, reject a well-formed but unknown
name clearly, and fail closed rather than open when the tenant's own API
(the authority on environments) cannot currently be reached. Issue #9's own
plan resolved most of the design up front — the allowlist regex, the exact
ordering, the "no cache, ever" rule — leaving one decision genuinely open at
implementation time: what `boundary` atom a purely local validation failure
should be tagged with, given `Nucleus.Backend`'s registry has no
`:environments` entry.

## Decision

### Allowlist, not denylist, for the environment short name

`Nucleus.Environments.validate_name/1` rejects anything that is not a
binary, is empty, contains `..`, `/`, `\`, or a null byte, exceeds 64
characters, or fails `~r/\A[a-z0-9][a-z0-9-]*\z/`. The regex is the actual
gate; the explicit checks preceding it exist for clearer error context, not
because the regex would let any of them through. A three-sequence denylist
(`..`, `/`, `\`) — all the wiki's error matrix names — passes through
percent-encoded traversal (`%252e`, which decodes once to `%2e` by the time
Phoenix hands it to `handle_params/3`, not twice to `..`), unicode
lookalikes (a fullwidth solidus), and control characters. An allowlist
cannot, by construction, and `PRX-A04` already establishes this project's
stance that percent-encoded traversal must be blocked for the same class of
input.

### `fetch/2`'s ordering is the whole of `SEC-A15`'s contract

`validate_name/1` runs as `fetch/2`'s first statement, with `with :ok <-
validate_name(name) do ... end` making an early return the only path an
invalid name can take — no adapter call, no path construction reachable
from that branch. `TenantApi.list_environments/1`'s `:unavailable` and
`:not_configured` both collapse to `:unavailable` (`SEC-A17` — a
misconfigured deployment must fail closed, not open, exactly like an
unreachable one); `:auth_expired` passes through untouched, left for
`SEC-S7`. Resolution matches by `short_name` against every environment
returned, archived included (`ENV-A06`) — filtering archived environments
out of navigation is `NucleusWeb.EnvironmentsHook`'s job, a different
question asked by a different caller.

### No cache, no fallback list — structurally, not just by omission

`fetch/2` calls `TenantApi.list_environments/1` fresh on every call and
never stores the result anywhere between calls. `SEC-A17`'s precondition —
"unreachable, and no cached list is available" — is otherwise the only
branch that would ever execute, given the stateless constraint
(`0001-no-local-datastore.md`) means no cache could exist here without
deliberately building one. Not building one keeps the fail-closed guarantee
single-path and untested-second-path-free, per the ticket's own explicit
instruction.

### Validation errors are tagged `boundary: :tenant_api`

The one decision the ticket left open. `Nucleus.Backend.Error.new/4` takes
an arbitrary atom for `boundary`, and no `:environments` boundary is
registered in `Nucleus.Backend`'s `@impls` map — introducing one purely for
error attribution would create an atom that exists nowhere else in the
selection/registry system this project already has for boundaries.
`validate_name/1` is pure and performs no I/O of its own, but it exists
entirely to gate the `:tenant_api` boundary before a call reaches it — the
same relationship `Nucleus.Backend.Faults.maybe_fault/1` already has when a
local implementation tags an injected fault with the boundary it was called
for. Tagging validation failures `:tenant_api` keeps every error this
module returns attributable to the one boundary a reader would actually
look at.

### Validated in `handle_params/3`, not `mount/3`

`NucleusWeb.SecretsLive` re-validates on every params change, not only on
initial mount. A `<.link patch={...}>` between two environments does not
remount the LiveView, so a check placed in `mount/3` would let a user patch
from a validated environment straight into an unvalidated one — silently
defeating `SEC-A15`–`A17` for every navigation after the first.

### Three states reuse `<.empty_state>`; no bespoke error component

No three-distinct-state error pattern existed anywhere in this codebase
before this ticket. `<.empty_state id icon message>`'s own moduledoc already
frames it as message-agnostic — "callers decide what message to pass, this
component does not distinguish empty from failed" — so three calls with
distinct `id`s, icons, and copy satisfy the requirement's "three **distinct**
states with distinct DOM IDs and distinct copy" without introducing a second
component that would duplicate the same markup for no behavioural gain.

## Consequences

### Positive

- `Nucleus.Environments` is the single place a raw environment name is ever
  validated; `Nucleus.Secrets.Path.build/2`'s existing "assumes pre-validated
  input" doc note is now backed by exactly one caller that keeps that
  promise.
- The zero-adapter-call guarantee is checked structurally, not inferred: the
  test swaps in a `Nucleus.TenantApi` implementation that raises if called
  at all, so a future refactor that accidentally reordered `fetch/2` would
  fail loudly rather than passing for the wrong reason.
- `SEC-S2`–`SEC-S7` all mount through `handle_params/3`'s resolved
  `:environment_status`/`:resolved_environment` assigns without re-deriving
  any of this ladder themselves.

### Negative

- No telemetry event or call counter was added to the local `TenantApi`
  implementation, which the ticket's plan named as something to "consider."
  The raising-fake test achieves the same proof for this ticket without it;
  if a later ticket needs to assert call counts against the *real* HTTP
  implementation too, that instrumentation still does not exist.
- Replacing `NucleusWeb.SecretsLive` wholesale broke two pre-existing tests
  (`shell_test.exs`, `secrets_flow_test.exs`) that asserted against the
  placeholder's `#secrets-not-implemented` id. Both were updated in this
  ticket's own commit rather than left for a follow-up, since ADR-0006 and
  the placeholder's own moduledoc already told every reader this breakage
  was coming.

## Alternatives considered

**A three-character denylist (`..`, `/`, `\`), matching the wiki's error
matrix literally.** Rejected — see "Allowlist, not denylist" above; it is a
strictly weaker check than the allowlist for the same three characters plus
everything else in scope for `SEC-A15`.

**A new `:environments` boundary atom for validation errors.** Rejected.
`Nucleus.Backend`'s boundary registry (`:secrets`, `:tenant_api`) is meant to
be exhaustive and swappable-implementation-backed; a boundary atom that maps
to no registered implementation would be a name that exists only for error
tagging, not a boundary in the sense the rest of the codebase uses the word.

**Caching `list_environments/1`'s result for the lifetime of a socket, to
avoid a network round trip on every patch.** Rejected outright by the
ticket and reaffirmed here: `SEC-A17`'s fail-closed guarantee depends on
"unreachable and no cache" being the only state that exists, and a cache
would additionally mean a `fetch/2` that starts returning stale answers
after an environment is added or archived upstream, with no invalidation
signal to know when.

## References

- SEC-S1 (issue #9) — the deciding issue, including the accepted
  implementation plan this ADR mostly confirms rather than overturns
- `docs/adr/0002-backend-adapter-boundaries.md` — the `Nucleus.Backend.Error`
  kind vocabulary (`:invalid`, `:not_found`, `:unavailable`,
  `:not_configured`, `:auth_expired`) this module maps onto
- `docs/adr/0006-application-shell-and-live-session-composition.md` — the
  placeholder `SecretsLive` this ticket replaces wholesale, and the
  sidebar-degrades-vs-Secrets-fails-closed asymmetry this ADR's ordering
  decision preserves rather than reconciles
- `docs/adr/0007-secrets-store-adapter.md` — "`SEC-S1` cannot lean on this
  boundary for that validation and must do it independently," which this
  ADR is the independent answer to
- Wiki [Secrets](https://github.com/dave-bell/nucleus/wiki/Secrets)
  `SEC-A15`–`A17`; [Environments](https://github.com/dave-bell/nucleus/wiki/Environments)
  `ENV-A06`; wiki [ADR-0002](https://github.com/dave-bell/nucleus/wiki/ADR-0002-Security-Hardening)
  §4, the source of the fail-closed rule
