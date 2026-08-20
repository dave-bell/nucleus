# ADR-0019: M2M Client Detail — Mount-Time Audit Guard and the Seconds-Based Token Validity Correction

## Status

Accepted — 2026-08-20

Decided on [M2M-S3](https://github.com/dave-bell/nucleus/issues/36). Builds on
`0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md` (the first
real `Audit.emit/2` call site, and the `audit_user/1`/`$callers`-fallback
conventions this ticket's own call site reuses unchanged) and
`0018-m2m-clients-listing-module-split-and-dom-ids.md` (the two-module split
and `Show.mount/3` shape this ticket fills in).

## Context

`M2M-A03` requires a `m2m_client_viewed` audit record per client-detail
open; `M2M-A16` requires the displayed token validity to pluralise
correctly. Two things the issue's plan left unresolved (or got wrong) before
implementation:

1. **The plan's `m2m_client_viewed` guard left the disconnected render
   unaddressed.** The issue thread settled that the audit emission must be
   guarded by `connected?(socket)` — `mount/3` runs once for the disconnected
   (static) render and once more for the connected render, and every other
   `Audit.emit/2` call site in this codebase is event-driven (`handle_event`),
   not mount-driven, so this is the first time that distinction matters. What
   the thread did not settle: if the audit call is skipped on the
   disconnected pass, is the client's data skipped too, or resolved by some
   other path?
2. **The plan's `TokenValidity.humanize/1` was two-tier and hours-only,**
   `humanize(hours :: integer() | nil)`, `1` → `"1 hour"`, everything else
   pluralised. `docs/requirements/M2M-Clients.md`'s actual `M2M-A16` text is
   three-tier — hours, else minutes, else seconds, each singular at exactly
   `1` — and `Nucleus.M2M.ClientDetail` (already shipped by EN-10 / #33)
   carries `token_validity_seconds`, not `token_validity_hours`. The plan
   predates the struct it was describing.

## Decision

### `connected?(socket)` selects the function, not just whether to call it

`Show.mount/3` calls `Nucleus.M2M.fetch/2` (no audit) on the disconnected
pass and `Nucleus.M2M.view/2` (`fetch/2` + `Audit.emit(:m2m_client_viewed,
...)`) only once `connected?(socket)` is true:

```elixir
result =
  if connected?(socket) do
    M2M.view(client_id, scope)
  else
    M2M.fetch(client_id, scope)
  end
```

This keeps both Phoenix lifecycle passes rendering the same, correct client
detail — no blank-then-populate flicker — while the one-time audit side
effect fires exactly once per human page open. The alternative (skip
resolution entirely on the disconnected pass, render nothing until
connected) was rejected: it would make the static HTML a placeholder shell
on every load, a regression from `Index`'s existing behaviour of resolving
data on both passes unconditionally. The cost is one extra
`Nucleus.M2M.Clients.describe_client/1` call per page open (the disconnected
pass's own `fetch/2`) — a single-client `DescribeUserPoolClient`, not the
fan-out `Index`'s own ADR (`0018`) already accepts paying twice per list
load.

This is the second real call site for `Audit.emit/2` from application code
(after `Nucleus.Secrets.reveal/3`, `0011`) and the first triggered by
`mount/3` rather than `handle_event/3`. `Scope.audit_user/1` and the test
sink's `$callers` fallback (`0011`) apply unchanged — `Phoenix.LiveViewTest`
sets `$callers` on a mounted view's process regardless of which callback
emits, so no new test infrastructure was needed to assert on it.

### `TokenValidity.humanize/1` takes seconds, three tiers, largest exact unit wins

```elixir
@spec humanize(seconds :: pos_integer() | nil) :: String.t()
```

Whole hours read in hours, else whole minutes read in minutes, else seconds
— singular at exactly `1` in every tier, `nil` reads `"not set"`. This
matches `docs/requirements/M2M-Clients.md`'s `M2M-A16` text and
`ClientDetail.token_validity_seconds`'s actual shape, not the issue body's
draft. `Nucleus.M2M.Clients.Cognito.token_validity_seconds/1` (EN-10 / #33,
already shipped) normalises Cognito's `AccessTokenValidity` +
`TokenValidityUnits` — seconds, minutes, hours, or days — to seconds before
this function ever sees it; the seeded local fixture at `450` seconds (not
a whole number of minutes) is the case that proves the two compose, rather
than a hypothetical.

### A small shared formatter, not two private copies

`NucleusWeb.M2MClientsLive.Format.created_date/1` is called by both
`Index` and `Show` for the one field both render the same way
(`Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")`), with a `nil` clause
`Show` needs and `Index` does not (`Index` takes its own
`created_date_error`-driven DOM branch for a per-row describe failure;
`ClientDetail` has no equivalent per-field error kind, so `Show`'s `nil` is
a client this feature didn't create arriving with no reliable value).
Matches Decision 7's own reasoning (`0018`) for why `States` is a real
module and not a copy-paste starting point — applied here to a formatter,
not markup.

## Consequences

### Positive

- No flicker between the disconnected and connected render, and exactly one
  audit record per human open, pinned by a test that opens the same client
  twice and asserts two independent records (`test/nucleus_web/live/m2m_clients_live_test.exs`).
- The `connected?(socket)`-gated dual-path is the pattern any future
  mount-triggered audit call site in this codebase should reach for first,
  rather than re-deriving it — the same role `0011`'s `audit_user/1`/
  `$callers` conventions already play for event-driven call sites.
- `TokenValidity.humanize/1` and the Cognito adapter's unit normalisation
  are proven to compose by a real seeded fixture, not asserted independently
  of each other.

### Negative

- One extra `describe_client/1` call per page open (disconnected pass) that
  a design skipping disconnected-pass resolution would not pay. Accepted as
  consistent with `Index`'s existing double-fetch-per-load behaviour, and
  small next to a single-client describe.
- `Format.created_date/1` is a two-call-site module for a three-line
  function — a low bar for extraction, justified here only because this
  codebase has an explicit, precedent-setting rule (Decision 7, `0018`)
  against letting two LiveView modules maintain the same rendering logic
  independently.

## Alternatives considered

**Skip client resolution entirely on the disconnected pass, populate only
once connected.** Rejected — regresses to a blank shell on every static
load, unlike `Index`'s existing behaviour, for a saving (one adapter call)
too small to justify the flicker.

**Call `Audit.emit/2` directly from `Show`, bypassing `view/2`.** Rejected
— `Nucleus.M2M.view/2` exists specifically so the fetch-plus-audit pairing
lives in one tested context function, matching `Nucleus.Secrets.reveal/3`'s
shape; duplicating the emission in the LiveView would leave two places that
must agree on the event name and detail keys.

**Keep `TokenValidity.humanize/1` as the plan drafted it (hours-only,
`nil | integer` hours).** Rejected — does not match either the requirement
text (`M2M-A16` is three-tier) or the struct it must read
(`token_validity_seconds`); shipping it as drafted would have been visibly
wrong against the wiki on the first non-hour fixture.

## References

- M2M-S3 (issue #36) — the deciding issue
- `docs/adr/0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md`
  — the audit-emission and test-sink conventions this ticket's call site
  reuses
- `docs/adr/0018-m2m-clients-listing-module-split-and-dom-ids.md` — the
  module split and `Show.mount/3` shape this ticket fills in, and Decision
  7's "not a copy-paste starting point" reasoning this ADR extends to
  `Format`
- `docs/requirements/M2M-Clients.md` — `M2M-A03`, `M2M-A15`, `M2M-A16`'s
  actual (three-tier) text
- `lib/nucleus/m2m/clients/cognito.ex:256-271` — EN-10's Cognito unit
  normalisation this ticket's formatter composes with
