# ADR-0025: Applications Listing — Single-Module Route Shape, Name-Derived DOM Ids, and Pre-Fixed Placeholder Cells

## Status

Accepted — 2026-08-26

Decided on [APP-S1](https://github.com/dave-bell/nucleus/issues/58). Builds on
`0018-m2m-clients-listing-module-split-and-dom-ids.md` (the immediately
preceding listing, whose module-split and DOM-id decisions this ADR reaches
the opposite conclusion on for stated reasons) and
`0010-secrets-listing-gate-collapse-and-dom-ids.md` (the DOM-id-contract
precedent both listings follow), and consumes
`0022-nomad-jobs-adapter.md`'s `Nucleus.NomadJobs.list/1` and `Job` struct
and `0006-application-shell-and-live-session-composition.md`'s
`live_session` hook ordering.

## Context

`APP-A01` requires the tenant's deployed applications be listed with name,
status, version, image, and schedule, and requires periodic child jobs never
appear as their own rows; `APP-A06`–`APP-A08` require an empty state, per-kind
error states with the shell intact, and no mutating affordance anywhere.

This is the third listing view in the codebase, after Secrets (ADR-0010) and
M2M Clients (ADR-0018). Most of the shape was therefore settled precedent and
needed no decision — `stream/3` plus a separate count assign, exhaustive
`Nucleus.Backend.Error.kinds/0` handling collapsed to named states, a
`States` sibling module. Three questions were **not** settled by that
precedent, and one of them the ticket body got wrong in a way only
implementation could surface:

1. **Route shape.** ADR-0018 decided M2M's listing as two modules
   (`Index`/`Show`, the `phx.gen.live` split) and recorded that decision as
   binding. Whether that split is the standing convention for every
   subsequent listing, or was specific to M2M having a per-item detail route,
   was ambiguous — and Applications has no detail route at all.
2. **Row and cell DOM ids.** Both prior listings recorded an explicit
   hash-versus-plain decision justified by the natural key's *validating
   allowlist*: Secrets hashes the ARN because a secret `key` admits unicode,
   spaces, and dots; M2M uses `client_id` directly because
   `Nucleus.M2M.ClientId`'s `~r/\A[A-Za-z0-9_+]{1,128}\z/` leaves nothing to
   sanitise. `Nucleus.NomadJobs.Job` has **no** validating allowlist for any
   field, so neither precedent's justification transfers unexamined.

   The ticket body's DOM-id contract compounded this by specifying
   `#job-{id}-version`, `#job-{id}-status`, and so on. `Job.t()` has no `id`
   field — ADR-0022 fixed its fields as `name, status, version, namespace,
   image, cron, periodic?, detail_error`. The contract's `{id}` had no
   referent, and implementation had to choose one.
3. **How much of `APP-S2`'s markup to fix now.** Version, image, and schedule
   *content* is explicitly `APP-S2`'s (#59) scope, but whether this ticket
   ships those columns at all — and if so, whether their DOM ids are settled
   here or there — determines whether #59 edits this ticket's markup
   structure or only its cell bodies.

## Decision

### One `NucleusWeb.ApplicationsLive` module, not ADR-0018's Index/Show split

A single LiveView at `/applications`, with
`NucleusWeb.ApplicationsLive.States` as its only sibling, registered in the
existing `:authenticated` `live_session` and inheriting `ScopeHook` then
`EnvironmentsHook` in ADR-0006's fixed order.

ADR-0018's split is **not** a general listing convention, and this ADR
records that explicitly so the next listing does not have to re-derive it.
That ADR's own reasoning was that M2M's `/m2m/clients` and
`/m2m/clients/:client_id` are "two distinct pages, not one page with several
states," reached only by `navigate` — the split followed from the existence
of a second route. Applications is one screen, one table, no drill-down, so
there is no second page to split into and nothing for a `Show` module to do.

The correct reading of ADR-0018 is therefore: *match the module count to the
route count.* Both it and this ADR follow that rule and reach different
answers because they have different route counts.

There is likewise no `handle_params/3` — `/applications` carries no
identifier, so nothing a `<.link patch>` could change without a remount, and
the single fetch happens in `mount/3`.

### Row and cell DOM ids derive from `Job.name`, unhashed

`stream_configure(:jobs, dom_id: &dom_id/1)` produces `"job-" <> name`, and
per-cell ids are `"job-" <> name <> "-" <> column`, resolving the ticket
body's unreferenced `{id}` to `name`. `name` is the only field on `Job.t()`
that identifies a job, so this was the sole available choice given ADR-0022's
struct; it is recorded as a decision because of what it rests on, not because
there was an alternative field.

Every row also carries `data-job-name={job.name}`, so `APP-S2` and any later
ticket read the authoritative name from the attribute rather than parsing it
back out of an element id — the same contract ADR-0018 set with
`data-client-id`.

**What makes this safe is an invariant owned by another module, not a
property of the id scheme.** `Job.name` is assigned straight from the Nomad
API response (`Job.from_api/3`: `name: stub["Name"]`) with no validation,
allowlist, or sanitisation of any kind. Nomad child job names *do* contain a
forward slash — `acme-nightly-report/periodic-1755000000` is a seeded example
— and a `/` in an element id makes the id unaddressable by CSS selector.
Verified, not assumed: `LazyHTML` raises rather than returning no match.

```
LazyHTML.filter(frag, "#job-acme-nightly-report/periodic-1755000000-status")
** (ArgumentError) got invalid css selector:
   #job-acme-nightly-report/periodic-1755000000-status
```

The scheme works only because `Nucleus.NomadJobs.Job.child?/1` excludes every
`ParentID`-bearing stub at the boundary, so no `/`-bearing name reaches the
template. That exclusion exists to satisfy `APP-A01`'s collapsing
requirement; the DOM-id scheme's addressability is a second, undeclared
consumer of it. If a future change to `Nucleus.NomadJobs.list/1` starts
returning children for any reason, the visible symptom is not a duplicated
row — it is every affected cell id becoming unselectable, and the test that
would catch it raising `ArgumentError` rather than failing an assertion.

Hashing `name` (Secrets' approach) was rejected, but on a narrower basis than
ADR-0018 rejected it for `client_id`: there, no character existed that a hash
would have helped with. Here such characters demonstrably exist and are
merely filtered out upstream. The plain name is kept because it makes
`APP-S2`'s tests and every future selector legible, and because `docs`
recording the invariant is cheaper than an opaque id — but the trade is real,
and this is the entry that records it.

### The name-ascending sort lives in the LiveView, not the boundary

`Enum.sort_by(jobs, &{String.downcase(&1.name), &1.name})` — case-insensitive
with an exact-name tiebreak — matching `Nucleus.M2M.list/1`'s identical
expression. `Nucleus.NomadJobs.Local.list_jobs/1` returns seed-file order and
the real adapter returns JSON-decoded order; neither is a stable sort, and
ADR-0022 did not make ordering part of `list/1`'s contract. The sort stays at
the rendering layer rather than being retrofitted into the boundary, so
`list/1`'s contract is unchanged and the ordering requirement sits with the
view that actually has one.

### Every column's DOM id is fixed now; three render as empty placeholders

Version, image, and schedule ship as empty `<td>` elements at their final
ids. `APP-S2` (#59) fills in cell *content* only and touches no markup
structure — the same service ADR-0010 performed for `SEC-S3`–`S6` and
ADR-0018 for the M2M listing.

| Column | This ticket | `APP-S2` (#59) adds |
|---|---|---|
| Name | full text | — |
| Status | raw status text | colour distinction (`APP-A02`) |
| Version | empty cell, id fixed | version text (`APP-A03`) |
| Image | empty cell, id fixed | image `name:tag` (`APP-A03`) |
| Schedule | empty cell, id fixed | cron / explicit no-schedule (`APP-A04`, `APP-A05`) |

### Error kinds collapse to three named states plus a generic fallback

`:not_configured` → `#applications-misconfigured`, `:unavailable` →
`#applications-unavailable` (the only state carrying a retry control),
`:auth_expired` → `#applications-auth-expired`, and every remaining kind →
`:unavailable`. `<Layouts.app>` stays intact in all of them, satisfying
`APP-A07`'s "rest of the shell remains usable". This mirrors
`NucleusWeb.M2MClientsLive.States` deliberately rather than inventing a
second pattern, and accepts the same fallback trade ADR-0018 recorded.

### `APP-A08` is structural, and the test is a re-proof

`Nucleus.NomadJobs` defines no create, update, or delete callback, so
read-only already holds one layer below the UI. The negative test asserting
no create/edit/delete/restart/redeploy control or text inside
`#applications-table` proves the template adds none either — deliberately
landed with the first render of the view, per the ticket's own reasoning,
rather than with `APP-S2`.

## Consequences

### Positive

- The module-count-matches-route-count rule is now written down, so the next
  listing ticket reads one sentence instead of inferring a convention from
  ADR-0018 and getting it wrong in either direction.
- `APP-S2` (#59) inherits a complete DOM-id contract and a `States` module,
  so it can be a content-only change — no markup-structure churn in a
  follow-up PR, and no second ticket independently inventing cell ids.
- `NucleusWeb.ApplicationsLive.States` mirrors `M2MClientsLive.States`
  closely enough that the third such module is a strong candidate for
  extraction, should a fourth listing appear.
- `list/1`'s contract stays as ADR-0022 wrote it; ordering is not
  retroactively pushed into a boundary that never promised it.

### Negative

- **Cell-id addressability depends on `Job.child?/1`, across a module
  boundary, with nothing enforcing it at the rendering layer.** The
  LiveView-level test that no seeded child renders is the guard, and it is a
  text-absence check (`refute html =~ child_name`) rather than a selector
  assertion — see the deliberate divergence below. A child leaking from
  `list/1` breaks selectors rather than merely adding a row.
- `Job.name` has no validating allowlist at all, so this ADR cannot claim
  what ADR-0018 could — that the id is *inherently* safe. Any future field
  used in a DOM id from this struct needs the same examination rather than
  citing this decision as settled precedent.
- The generic error fallback folds `:not_found`, `:already_exists`, and
  `:invalid` into `#applications-unavailable`. If `list/1` ever returns one
  for a real reason it renders as "can't reach Nomad" until the `case` is
  revisited — the same trade ADR-0010 and ADR-0018 already accept.
- Three columns render visibly empty until `APP-S2` lands, so `/applications`
  is briefly a partially-populated table on the default branch.
- `NAV-A03` (active-section highlighting) remains unclaimed even though the
  sidebar link is now live, matching `M2M-S2`'s precedent — a working view
  does not by itself satisfy the "visually distinguished as active" clause.

## Alternatives considered

**Two modules (`Index`/`Show`), applying ADR-0018 as a standing convention.**
Rejected — there is no second route for `Show` to serve. Following the split
mechanically would have produced a module with no route, no template, and
nothing to test.

**Hashing `Job.name` for row and cell ids, as `SecretsLive` hashes the ARN.**
Rejected — but on the residual-risk basis recorded above, not ADR-0018's
"no such character exists" basis. A hash would make every `APP-S2` selector
opaque and require a name→id helper in tests, to defend against a case
`Job.child?/1` already excludes. Revisit if `list/1`'s child-exclusion
guarantee is ever relaxed.

**Sanitising `name` into the id (replacing `/` with `-`) instead of relying
on upstream filtering.** Rejected as the worse failure mode: it would make a
leaked child job render an id that *looks* valid and silently collides with a
sibling's, rather than failing loudly. Given children are excluded upstream,
the sanitiser would be dead code whose only effect is to mask the regression
it appears to guard against.

**Adding the sort to `Nucleus.NomadJobs.list/1`.** Rejected — expands a
boundary contract ADR-0022 deliberately scoped, to serve one caller's
presentation requirement. `Nucleus.M2M.list/1`'s precedent puts the identical
sort at the same layer.

**Deferring the version/image/schedule columns entirely to `APP-S2`.**
Rejected — #59 would then own both the markup structure and the cell
content, reopening this ticket's table markup in a follow-up PR, which is
precisely what ADR-0010's DOM-id contract exists to prevent.

## Deliberate divergence from the ticket's test plan

The issue's snippet proposed
`refute has_element?(view, "#job-#{seeded_child_job_id()}-status")`. That
cannot work: the selector string it builds contains a `/`, which LazyHTML's
parser rejects outright with `ArgumentError`, so the assertion raises instead
of passing or failing. The test uses `refute html =~ child_name` — a
text-absence check proving the child renders nowhere at all, which is
strictly stronger than the id-absence check intended, and does not depend on
a selector the parser cannot accept.

This is the same class of finding as ADR-0012's discovery that
`LazyHTML.query/2` returns a struct rather than a list and made several
guards vacuous. Both are now recorded together in `living-notes.md`'s
Gotchas, since either one silently produces a test that does not test what it
appears to.

## References

- APP-S1 (issue #58) — the deciding issue, including the `#job-{id}-*`
  DOM-id contract whose `{id}` had no referent on `Job.t()`
- APP-S2 (issue #59) — the downstream consumer of this ticket's DOM-id
  contract and `States` module
- `docs/adr/0018-m2m-clients-listing-module-split-and-dom-ids.md` — the
  module-split and plain-id decisions this ADR bounds to their route count
- `docs/adr/0010-secrets-listing-gate-collapse-and-dom-ids.md` — the
  DOM-id-contract-for-later-tickets precedent
- `docs/adr/0022-nomad-jobs-adapter.md` — `Nucleus.NomadJobs.list/1`,
  `Job.child?/1`'s `ParentID` filtering, and the `Job.t()` field list with
  no `id`
- `docs/adr/0006-application-shell-and-live-session-composition.md` —
  the `live_session` hook order this route inherits
