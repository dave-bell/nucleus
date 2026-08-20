# ADR-0018: M2M Clients Listing — Context-Layer Gate Collapse, Two-Module Route Split, and Plain-ID DOM Ids

## Status

Accepted — 2026-08-20

Decided on [M2M-S2](https://github.com/dave-bell/nucleus/issues/35). Builds on
`0010-secrets-listing-gate-collapse-and-dom-ids.md` (the direct precedent this
ADR follows one feature over), `0017-m2m-naming-deny-list-and-resolution-gate.md`
(the `visible?/1` predicate this ticket's list filter reuses rather than
duplicating), and `0006-application-shell-and-live-session-composition.md`
(the `live_session` hook ordering both new routes inherit).

## Context

`M2M-A01` requires every visible M2M client be listed with its name, ID, and
creation date; `M2M-A02` requires a clear empty state with a prominent create
affordance. Three questions needed settling before implementation, one of
them — the route shape — already closed on the issue thread as a
`needs-decision` before work began; the other two surfaced during
implementation itself, the same way ADR-0010 records questions SEC-S1's
original plan left open or got wrong:

1. **Route shape.** The ticket's own plan was modelled on `SEC-S1`
   (`SecretsLive`, one module switching on `handle_params/3` across several
   states of one route) applied to M2M's nested `/m2m/clients` +
   `/m2m/clients/:client_id`. Whether that model actually fits a route that
   is two distinct pages, not one page with several states, needed deciding
   before either module could be written.
2. **Row DOM ids.** `SecretsLive` hashes the ARN because a secret's natural
   key (its `key`) can contain unicode, spaces, and dots with no defined CSS
   sanitiser. Whether `Nucleus.M2M.Client.client_id` needs the same
   treatment, or is DOM-safe as-is, was not decided by the ticket body.
3. **The create affordance in the empty state.** `AGENTS.md`'s documented
   `hidden only:block` trick for stream empty states only works when the
   empty block is the stream comprehension's only sibling — `M2M-A02`
   requires the create button stay visible in that same state, which breaks
   the trick's precondition.

## Decision

### Two LiveView modules, not one switching on `handle_params/3`

`NucleusWeb.M2MClientsLive.Index` (`/m2m/clients`) and
`NucleusWeb.M2MClientsLive.Show` (`/m2m/clients/:client_id`) — the
`phx.gen.live` module split (`deps/phoenix/priv/templates/phx.gen.live/{index,show}.ex.eex`,
verified against the pinned 1.8.9 template, not assumed), not one module
switching on `live_action`. Both live in the existing `:authenticated`
`live_session`, inheriting `ScopeHook` then `EnvironmentsHook` in that fixed
order, same as `SecretsLive`.

The `SEC-S1` model fits a route serving several *states* of the same page,
which patch between each other and need `handle_params/3` to re-validate on
every patch. M2M's nested route is two distinct pages reached only by
`navigate` — there is nothing to patch between, so nothing to re-validate.
Following the split also removes a trap a single-module design would
otherwise need a dedicated test to catch (patching back to `:index` needing
`reset: true` or the stream returning empty), and avoids a modal-over-list
detail view entirely, which matters because M2M-S6's one-time credentials
panel (#39) opens *from* the detail view — a modal detail here would make
that modal-over-modal, directly into ADR-0012's module-global `focusStack`
double-pop hazard.

Consequences of the split, both load-bearing for this ticket and the ones
after it:

- **`Show` resolves in `mount/3`, not `handle_params/3`.** Every navigation
  to a different `client_id` is a fresh remount, so `phx.gen.live`'s own
  `Show.mount/3` shape applies directly (`show.ex.eex:31`). This ticket ships
  `Show` as a stub — `mount/3` renders the shell only, no gate, no
  `Nucleus.M2M.fetch/2` call — so the route exists and compiles without
  pulling M2M-S3's work forward.
- **`Show` does not fetch the list.** `Cognito.list_clients/0` fans out one
  `DescribeUserPoolClient` per client (`lib/nucleus/m2m/clients/cognito.ex:167-176`,
  `max_concurrency: 10`); a modal-over-list detail would pay that whole
  fan-out on every deep link for data it doesn't render. `Show` (M2M-S3) will
  call `Nucleus.M2M.fetch/2` directly instead.
- **The row control is a `<.link navigate={...}>`, not an event.** Explicit
  `client_id` interpolation (`~p"/m2m/clients/#{client.client_id}"`), not
  `~p"...#{client}"` — `Nucleus.M2M.Client` implements no `Phoenix.Param`,
  and deriving one would put routing concerns in a data carrier that has
  none today. No `handle_event` clause is needed for the row control.
- **Shared error states are a real component, `NucleusWeb.M2MClientsLive.States`,
  not a copy-paste starting point.** Two modules can't share markup by
  accident. `Index` uses all three functions (`misconfigured/1`,
  `unavailable/1`, `auth_expired/1`) this ticket adds; `Show` (M2M-S3) will
  import the same module and add its own `#m2m-client-invalid-id`/
  `#m2m-client-not-found`.

### One call to `Nucleus.M2M.list/1`, gate included — mirrors `Secrets.list/2`

`Nucleus.M2M.list/1` fails closed on `Nucleus.M2M.DenyList.suffixes/0` before
ever calling `Nucleus.M2M.Clients.list_clients/0`, filters the result through
`visible?/1` — the same predicate `Nucleus.M2M.fetch/2` already gates single
reads with (`0017`) — and sorts case-insensitively by `client_name` with the
raw name as a tiebreak (`Enum.sort_by(&{String.downcase(&1.client_name), &1.client_name})`),
identical construction to `Nucleus.Secrets.list/2`. `NucleusWeb.M2MClientsLive.Index`
calls only this function; there is exactly one place that can bypass the
deny-list gate for a listing request, matching ADR-0010's own reasoning for
collapsing `SecretsLive`'s two calls into one.

A `Client` with `created_date_error` set (its own per-row
`DescribeUserPoolClient` failed while listing — EN-10 / #33's Decision 6) is
filtered and sorted like any other row and is not dropped; degrading that one
row is `Clients.list_clients/0`'s job, not this function's.

**Emits no audit event**, the same deliberate omission `Nucleus.Secrets.list/2`
documents: the wiki's audit table has exactly three M2M events and listing
is not among them. Unlike Data Export's `nomad_vars_listed`, listing here
exposes no secret material — `Client.t()` has no secret field to begin
with — so there is nothing sensitive to attribute.

### Row DOM ids are the client ID directly, not a hash

Unlike `SecretsLive`'s ARN-hash, `Nucleus.M2M.ClientId`'s allowlist
(`~r/\A[A-Za-z0-9_+]{1,128}\z/`, `0017`) is already DOM-safe — there is no
unicode, space, or dot case to sanitise around. `stream_configure(:clients,
dom_id: &dom_id/1)` prefixes it (`"m2m-client-" <> client_id`) only to avoid
an id that could start with a digit; every row also carries
`data-client-id={client.client_id}`, so M2M-S3/S6 read the authoritative ID
from an attribute rather than parsing it back out of the element id, matching
the DOM-id contract the ticket tabulated.

### The create affordance sits outside the empty-state conditional

`#new-m2m-client-button` is rendered whenever `@status == :ok`, regardless of
`@client_count`, rather than inside `<.empty_state>`'s `:action` slot or
relying on the `hidden only:block` trick. `SecretsLive`'s own "New secret"
button already follows this shape for the identical reason: the trick only
applies when the empty block is the stream comprehension's only sibling, and
a create button rendered alongside the empty state breaks that precondition.
This ticket's plan independently reached the same conclusion `SEC-S2` did.

## Consequences

### Positive

- `Nucleus.M2M.list/1` is the one place a list request can bypass the
  deny-list gate; `NucleusWeb.M2MClientsLive.Index` has no second call site
  to audit, matching ADR-0010's own positive consequence for `Secrets.list/2`.
- `visible?/1` backs both `fetch/2` and `list/1` from one implementation, so
  a client hidden from the list cannot remain rotatable by URL — pinned by a
  dedicated test (`test/nucleus/m2m_test.exs`) rather than left to the two
  call sites happening to agree.
- `NucleusWeb.M2MClientsLive.States` gives M2M-S3 a written contract for its
  own error states, instead of that ticket guessing markup independently the
  way ADR-0010 gave `SEC-S3`–`S6` a DOM-id contract instead of four tickets
  each guessing a sanitisation scheme.
- No hash function exists for this feature to keep stable across a future
  `stream_insert/3` (M2M-S5/S6) — the DOM id is just the ID, so there is
  nothing to document as a liability the way ADR-0010 flags its own ARN hash.

### Negative

- `Show`'s stub carries no test of its own gate — none exists yet — so
  M2M-S3 replacing the stub body is the first point that route is actually
  exercised against a real, malformed, or out-of-tenant `client_id`. This
  ticket's own test only asserts the stub mounts without crashing on a valid
  ID reached by navigation.
- The three collapsed error states (`:misconfigured`, `:unavailable`,
  `:auth_expired`) fold `:not_found`, `:already_exists`, and `:invalid` into
  `:unavailable` by default, on the reasoning that `Nucleus.M2M.list/1` has
  no path that returns them today. If a future change to
  `Nucleus.M2M.Clients.list_clients/0` starts returning one of those kinds
  for a real reason, it will render as a generic "can't reach" message
  rather than its own state until `Index`'s `case` is revisited — the same
  trade `SecretsLive`'s exhaustive fallback already accepts.

## Alternatives considered

**One `M2MClientsLive` module, `handle_params/3` switching on `live_action`.**
Rejected — modelled on `SEC-S1`'s single-route, multi-state shape, which does
not describe M2M's two-distinct-pages shape; see Decision 1 above and
`phx.gen.live`'s own precedent.

**A modal-based detail view over the list, avoiding a second route
entirely.** Rejected — pays `Cognito.list_clients/0`'s per-client describe
fan-out on every deep link for data the detail view doesn't render, and
collides with M2M-S6's credentials panel opening from the detail view
(modal-over-modal, ADR-0012's `focusStack` hazard).

**Hashing `client_id` for the row DOM id, matching `SecretsLive` exactly.**
Rejected — `client_id`'s allowlist has no character `SecretsLive`'s hash was
introduced to work around; hashing here would add an opaque id with no
corresponding problem to solve.

**Using `AGENTS.md`'s `hidden only:block` trick for the empty state.**
Rejected — `M2M-A02` requires the create button visible in the empty state,
which is not the stream comprehension's only sibling once that button is
added; the trick's precondition does not hold here.

## References

- M2M-S2 (issue #35) — the deciding issue, including
  [Decision 7](https://github.com/dave-bell/nucleus/issues/35#issuecomment-5350928640)
  (route shape, decided before implementation started)
- `docs/adr/0010-secrets-listing-gate-collapse-and-dom-ids.md` — the direct
  precedent this ADR follows: one gated context call, DOM-id contract,
  exhaustive error-kind handling
- `docs/adr/0017-m2m-naming-deny-list-and-resolution-gate.md` — the
  `visible?/1` predicate this ticket's list filter reuses
- `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md` — the
  `focusStack` hazard the two-module split avoids rather than works around
- `deps/phoenix/priv/templates/phx.gen.live/{index,show}.ex.eex` — the
  module-split precedent Decision 7 follows
- `lib/nucleus/m2m/clients/cognito.ex:167-176` — the per-client describe
  fan-out `Show` avoids paying on every deep link
- Wiki [M2M-Clients](https://github.com/dave-bell/nucleus/wiki/M2M-Clients)
  `M2M-A01`, `M2M-A02`, and the audit events table
