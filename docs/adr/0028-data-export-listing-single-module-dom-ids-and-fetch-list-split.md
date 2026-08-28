# ADR-0028: Data Export Listing — Single Module, Unhashed Variable-Key DOM Ids, and the Fetch/List Audit Split

## Status

Accepted — 2026-08-27

Decided on [DEX-S1](https://github.com/dave-bell/nucleus/issues/73). Builds on
`0025-applications-listing-single-module-and-name-derived-dom-ids.md` (the
module-count-matches-route-count rule this ADR applies rather than
re-derives, and the DOM-id residual-risk framing this ADR follows for a
different key), `0010-secrets-listing-gate-collapse-and-dom-ids.md` (the
DOM-id-contract precedent both listings before this one followed), and
`0027-nomad-vars-adapter.md` (`Nucleus.NomadVars.Store`, `VariableSet.t()`'s
one-timestamp-per-set shape, and the enablement signal this ticket's gate
consumes). Also draws on `0019-m2m-client-detail-mount-audit-guard-and-token-validity.md`'s
`fetch/2`/`view/2` split, applied here for the first time to a *listing*
rather than a detail view.

## Context

`DEX-A01`, `A03`, `A12`, `A13`, `A14` require: detect whether Data Export is
enabled and show a clear message with no table when it is not; list every
configuration key and value unmasked; an empty state when enabled but
nothing is configured; a distinct error state when Nomad is unreachable,
shell intact; and no create-or-delete affordance of any kind.

This is the fourth listing view in the codebase, after Secrets (ADR-0010),
M2M Clients (ADR-0018), and Applications (ADR-0025). The module-shape
question ADR-0025 settled — *match the module count to the route count* —
answers itself here without re-litigation: Data Export has no per-item
detail route, so one module. Two questions were not settled by precedent:

1. **Row/cell DOM ids.** `VariableSet.t()`'s `items` is a
   `%{String.t() => String.t()}` with no validating allowlist on its keys at
   all — Nomad's own API restricts the variable *path* to an RFC3986-safe
   character set but places no charset restriction on an `Items` key beyond
   the 64KiB total-size cap. ADR-0025 faced the identical shape of problem
   for `Job.name` and resolved it by relying on an *upstream filter*
   (`Job.child?/1`) that removes every `/`-bearing name before the template
   ever sees one. No equivalent filter exists or could exist here — Data
   Export's `Items` keys are not filtered by anything, upstream or
   otherwise.
2. **The disconnected (static) render.** `Nucleus.NomadVars` exposes only
   one read function, and the ticket's plan called for gating the entire
   fetch behind `connected?(socket)` so the `nomad_vars_listed` audit event
   fires once per human page open, not once per disconnected-plus-connected
   `mount/3` pair. Implemented literally, this leaves the disconnected
   render with nothing to show — caught in review, not by any test written
   against the plan as given, since `Phoenix.LiveViewTest.live/2` connects
   before returning and so never exercises the disconnected pass at all.

## Decision

### One `NucleusWeb.DataExportLive` module, applying ADR-0025's rule directly

A single LiveView at `/data-export`, with `NucleusWeb.DataExportLive.States`
as its only sibling, registered in the existing `:authenticated`
`live_session`, `ScopeHook` then `EnvironmentsHook`. No `handle_params/3` —
the route carries no identifier — so the one fetch happens in `mount/3`.
This ADR does not re-derive ADR-0025's reasoning; it is the second
confirmation that the rule holds for a fourth listing with no detail route.

### Row and cell DOM ids use the raw configuration key, unhashed — a different resolution than ADR-0025's, for a different reason

`#var-{key}-value` uses the key exactly as it appears in `Items`, matching
`env_names`/`description` as displayed. This was **not** resolved by finding
an upstream filter analogous to `Job.child?/1` — none exists, and none
could: `Nucleus.NomadVars.Store` has no create/delete callback, so every key
that will ever reach this view was chosen by whoever provisioned the Nomad
variable, not filtered by Nucleus code at any layer.

The decision instead rests on **provenance, not filtering**: every key this
feature can show today (`description`, `env_names`, `destination_bucket`) is
an identifier Nucleus's own ops team defines when setting up the variable —
the same class of input as an environment variable name, not tenant-supplied
data. `DEX-A14` additionally guarantees no *new* key is ever created through
this feature, so the keyspace cannot grow through the UI itself. Hashing
(Secrets' approach) was rejected for the same reason ADR-0010 and ADR-0025
both gave: the key is not sensitive, is already visible in the adjacent
cell, and hashing it would only cost `DEX-S2`/future tickets' selector
legibility.

This is recorded as its own decision, distinct from ADR-0025's, because the
residual risk is real and the safety argument is different in kind — a
convention ops follows, not a filter the code enforces. A future key that
violates the convention (contains a `/`, say) produces exactly ADR-0025's
symptom: a technically-valid HTML `id` that is not a valid CSS selector, and
`LazyHTML`-backed test helpers raise `ArgumentError` rather than failing an
assertion. Nothing in this module detects or guards against that; it is an
ops-process failure, not a code path.

### `Nucleus.NomadVars.fetch/1` (no audit) and `list/1` (`fetch/1` plus audit) — the `M2M.fetch/2`/`view/2` split, applied to a listing for the first time

`Nucleus.NomadVars` originally exposed only `list/1`, matching the ticket's
plan literally: one call answering "is it enabled," "what's configured,"
and "why did it fail" together, auditing `nomad_vars_listed` on success.
`NucleusWeb.DataExportLive.mount/3` called this once, gated on
`connected?(socket)`, exactly as the plan specified — and the disconnected
render showed nothing at all, since no non-audited path existed to call
instead.

Caught in review: `NucleusWeb.M2MClientsLive.Show` (ADR-0019) already solves
this exact problem for a *detail* view by splitting `M2M.fetch/2` (no
audit) from `M2M.view/2` (`fetch/2` plus the audit emission), calling
`fetch/2` disconnected and `view/2` only once connected. `Nucleus.NomadVars`
gains the identical split: `fetch/1` resolves `Store.read()` with no side
effect; `list/1` is `fetch/1` plus `Audit.emit(:nomad_vars_listed, ...)` on
success. `mount/3` now calls `fetch/1` disconnected and `list/1` once
connected — the static HTML shows the real table, empty state, or error
state immediately, and the audit still fires exactly once per human page
open.

This is the first time this split has been applied to a *listing* rather
than a detail view — ADR-0018's and ADR-0025's listings both fetch
unconditionally in `mount/3` with no `connected?` gate at all, because
neither `Nucleus.M2M.list/1` nor `Nucleus.NomadJobs.list/1` emits an audit
event for a listing in the first place (per each boundary's own moduledoc).
`Nucleus.NomadVars.list/1` is the first listing-level context function that
*does* audit, which is what makes the gate — and therefore the split —
necessary here and not there.

**This does not generalize to a future listing of sensitive data.** The
split is safe only because Data Export configuration is not secret data —
`DEX-A03` states this explicitly, the same premise `Nucleus.M2M.fetch/2`'s
own split rests on for a client list. An unaudited `fetch/1`-shaped
counterpart, added specifically so the disconnected render has something
real to show, is itself an unaudited path to whatever it reads — that is
true regardless of whether a human ever actually loads the page
disconnected. A future listing over sensitive data cannot copy this pattern
by rote; it needs either unconditional auditing (both the disconnected and
connected calls) or a disconnected render that shows no real content at
all, accepting the blank-shell cost this ADR spent its Context section
arguing against.

### The enablement gate is a state, not a filtered error

`{:error, %Error{kind: :not_found}}` from `Nucleus.NomadVars.list/1`/`fetch/1`
maps to its own `:not_enabled` status and `#data-export-not-enabled`, with
no retry affordance — matching `Nucleus.NomadVars.Store`'s own moduledoc,
which states plainly that `:not_found` here means "not enabled," not "the
load failed." Every other kind collapses through
`NucleusWeb.DataExportLive.States` the same way ADR-0025 collapsed
`Nucleus.NomadJobs`'s: `:not_configured` → misconfigured,
`:auth_expired` → auth-expired, everything else (including `:conflict`,
which nothing here can produce yet) → `:unavailable` with a retry control.

### One shared "last modified," never per row

`VariableSet.t()` carries a single `modify_index`/`modified_at` for the
whole path (ADR-0027, DEX-D1's correction of the wiki), so it renders once,
outside the row loop, at `#data-export-modified-at` — never
`#var-{key}-modified`. This is a straightforward consumption of ADR-0027's
struct, not a new decision, but is named here because the wiki's original
per-key shape made the opposite choice look plausible to a reader who had
not seen that correction.

## Consequences

### Positive

- The module-count-matches-route-count rule (ADR-0025) now has a second,
  independent confirmation rather than resting on one data point.
- `Nucleus.NomadVars.fetch/1` exists for any future caller that needs the
  variable set without triggering an audit record — the same reusable seam
  `M2M.fetch/2` already provides for M2M.
- The disconnected render showing real content is now verified by a test
  that exercises the actual static HTTP response (`get/2` +
  `html_response/2`), not inferred from `live/2` succeeding — `live/2`
  connects before returning and would not have caught the original gap.

### Negative

- **Row/cell id addressability rests on an ops convention, not a code
  guarantee**, unlike ADR-0025's `Job.child?/1` filter. There is no test
  that can prove a future key will never contain a `/` — only a moduledoc
  comment recording the assumption. This is a strictly weaker guarantee
  than ADR-0025's, carried forward deliberately rather than accidentally.
- `Nucleus.NomadVars.list/1` now has two callers of `fetch/1` to keep in
  sync (itself, and `NucleusWeb.DataExportLive.mount/3`'s disconnected
  branch) where before there was one function and one call site. A future
  change to `fetch/1`'s contract must be checked against both.
- **The `fetch/1`/`list/1` split reads as a general "how to fix a blank
  disconnected render" recipe if lifted out of context — it is not one.**
  It is sound here only because the underlying data (Data Export
  configuration) is not sensitive; the same fix applied to a future
  sensitive-data listing would introduce an unaudited read of that data.
  Caught in review on this ticket's own PR, not by any test — recorded here
  and in `living-notes.md`'s Gotchas so the next listing checks data
  sensitivity before reusing this pattern rather than pattern-matching on
  "audited call gated behind `connected?/1`" alone.
- The generic error fallback folds `:already_exists`, `:conflict`, and
  `:invalid` into `#data-export-unavailable`, the same trade ADR-0010,
  ADR-0018, and ADR-0025 already accept for their own boundaries.

## Alternatives considered

**Hashing the variable key, mirroring Secrets' ARN hash.** Rejected — the
key is not sensitive and is already visible in the adjacent cell; hashing
would only cost `DEX-S2`'s future selectors, for no protection gained.

**Sanitising the key into the id (replacing `/` with `-`) instead of
documenting the residual risk.** Rejected for the same reason ADR-0025
rejected it for `Job.name`: it would make a future violating key render an
id that looks valid and silently collides, rather than failing loudly via
`LazyHTML`'s own `ArgumentError`. Given every key today is ops-provisioned,
the sanitiser would be dead code whose only effect is to mask the
regression it appears to guard against.

**Leaving `fetch_variables/1` gated entirely behind `connected?/1`, as the
ticket's plan specified literally, and adding an explicit `:loading`
skeleton state to the template instead of a second context function.**
Rejected — it would work, but reproduces the disconnected-static-render gap
one layer up (an empty-looking page until the socket connects) rather than
closing it, and diverges from `M2M.fetch/2`/`view/2`'s already-established
pattern for the identical problem. Adding `fetch/1` reuses a seam this
codebase already trusts instead of inventing a new one.

**Merging `fetch/1` and `list/1` into one function taking an `audit?:
boolean` option.** Rejected — `Nucleus.M2M`'s `fetch/2`/`view/2` split
already establishes two named functions, not one parameterised one, as the
convention for "the same read, audited or not." A boolean flag would read
correctly at the call site but hides the audit decision behind a value
instead of a name.

## References

- DEX-S1 (issue #73) — the deciding issue, and its comment thread's request
  to examine the variable-key DOM-id question explicitly rather than cite
  ADR-0025 unexamined
- `docs/adr/0025-applications-listing-single-module-and-name-derived-dom-ids.md` —
  the module-shape rule this ADR applies, and the DOM-id residual-risk
  framing this ADR follows for a key with a different safety argument
- `docs/adr/0010-secrets-listing-gate-collapse-and-dom-ids.md` — the
  DOM-id-contract-for-later-tickets precedent
- `docs/adr/0019-m2m-client-detail-mount-audit-guard-and-token-validity.md` —
  the `fetch/2`/`view/2` split this ADR applies to a listing for the first
  time
- `docs/adr/0027-nomad-vars-adapter.md` — `Nucleus.NomadVars.Store`,
  `VariableSet.t()`'s one-timestamp-per-set shape, and `:not_found` as the
  enablement signal this ticket's gate consumes
- DEX-S2 (issue #74) — the downstream consumer of this ticket's DOM-id
  contract, `fetch/1`, and `:modify_index` assign
