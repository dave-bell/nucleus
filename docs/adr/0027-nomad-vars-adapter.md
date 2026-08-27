# ADR-0027: Nomad Vars Adapter

## Status

Accepted — 2026-08-27

Decided on [EN-12](https://github.com/dave-bell/nucleus/issues/72). Builds on
`0002-backend-adapter-boundaries.md` (behaviour/real-local shape, the
seventh-error-kind warning this ticket triggers), `0003-shared-local-backend-seed.md`
(`Nucleus.Backend.Seed`), `0007-secrets-store-adapter.md` (the read+write
boundary shape and pure path/value-validator precedent this follows), and
`0022-nomad-jobs-adapter.md` (Decision 7, which named this boundary and its
shared transport in advance).

## Context

`:nomad_vars` is the read+write counterpart to `:nomad_jobs`'s read-only job
data — the boundary Data Export Configuration
(`docs/requirements/Data-Export-Configuration.md`) sits on. EN-11 built
`Nucleus.Nomad.Transport` deliberately anticipating this ticket (Decision 7:
"job reads and Nomad Variables are different capabilities with different
access levels... collapsing them into one switch would put a write callback
on the same boundary as `APP-A08`'s read-only guarantee"), so this ticket
extends that shared transport rather than building a second one.

The issue thread resolved five decisions before implementation began (path
template, boundary shape, CAS necessity, the `:conflict` error kind, and the
enablement signal), plus two corrections to what EN-11 had assumed about
`Nucleus.Nomad.Transport` needing no further change. This ADR is the
implementation-time record of one additional correction implementation
itself required, which the decision thread had no way to anticipate.

## Decision

### 1. Transport gains `:json`, and a widened, still-explicit status mapping

`Nucleus.Nomad.Transport.request/3` accepts a `:json` option, added to the
`Req.new/1` keyword list only when present — the two existing `:get` call
sites (`Nucleus.NomadJobs.Http`) pass no such option and are unaffected.
Status mapping widens from three branches to five, still an explicit `case`
with no default-to-success: `404` now maps to `:not_found` (previously
folded into the `:unavailable` catch-all), `409` maps to a new `:conflict`
kind, carrying the response body's `ModifyIndex` in `details.modify_index`
when Nomad's own conflict response includes one. A genuinely empty `200`
body — a legitimate outcome for a Nomad Variables write — now decodes to
`{:ok, %{}}` rather than the previous "nomad returned no body" `:unavailable`
error; an *undecodable* non-empty body is unchanged, still `:unavailable`.

### 2. `Nucleus.Backend.Error` gains a seventh kind, `:conflict`

Per `docs/adr/0002`'s own warning, a seventh kind means revisiting every
exhaustive `case`/`cond` matching on `Error.kind()`. Audited every such site
(`rg` for `kind: :` patterns and `Error.kinds()`) beyond the three the issue
body named by name: `applications_live.ex`,
`applications_live/states.ex`, `environments_live.ex`,
`m2m_clients_live/index.ex`, `m2m_clients_live/states.ex`,
`m2m_clients_live/show.ex` (two separate mappings), `secrets_live.ex` (four
separate mappings), `m2m/clients/cognito.ex`, `nomad_jobs/http.ex`,
`environments.ex`. Every one of them already carries a generic
`{:error, %Error{}}` (or equivalent) catch-all clause as its final branch —
`:conflict` falls through those unchanged, needing no code edit. This is
worth recording precisely because it means the "revisit every case" warning
was already satisfied by existing discipline, not by new code added here.

### 3. `Nucleus.NomadVars.Path.job_name/0` is the suffix of `path/0`, not a second literal

`"nomad/jobs/#{tenant_namespace}-data_export"` and
`"#{tenant_namespace}-data_export"` are read from `Nucleus.Scope.tenant_namespace/0`
at call time, matching `Nucleus.Secrets.Path`'s and `Nucleus.M2M.ClientName.prefix/0`'s
own per-call-read precedent rather than caching at compile time.

### 4. `Nucleus.NomadVars.Value.validate/1` returns a bare reason atom, not a wrapped `Error`

Diverges from `Nucleus.Secrets.Value` (which wraps in
`Nucleus.Backend.Error{kind: :invalid}`) by design, not oversight — mirrors
`Nucleus.M2M.Purpose.validate/1`'s shape instead: `:ok | {:error, :empty | :too_long}`.
The wrapping into a `Nucleus.Backend.Error` with whatever `field`/`key`
context is available is left to the calling context module (a future
`Nucleus.NomadVars`, DEX-S2/DEX-S4), the same division of labour
`Nucleus.M2M.create_client/2` already draws around `Purpose.validate/1`.

### 5. `Nucleus.NomadVars.VariableSet` carries one `modify_index`/`modified_at` for the whole set

Nomad Variables are path-addressed — one path holds an `Items` map for every
key, with a single `ModifyIndex`/`ModifyTime` for the whole path, not one per
key. The wiki's `{ variables: [{ key, value, last_modified }] }` response
shape (`Data-Export-Configuration.md:175`) cannot be built from a real Nomad
response; manufacturing a per-key timestamp would misrepresent data Nomad
does not return. DEX-D1 owns correcting the wiki to match.

### 6. `Nucleus.NomadVars.Store` — one behaviour, read + write, CAS-enforced

Mirrors `Nucleus.Secrets.Store`/`Nucleus.M2M.Clients`'s shape, not a
read-behaviour/write-behaviour split — rejected in the same terms
`docs/adr/0022` Decision 7 already gave for keeping `:nomad_jobs` and
`:nomad_vars` themselves separate. No create/delete callback: the variable
path already exists for any tenant with Data Export enabled, by
requirement. `write/2` takes the entire desired `Items` map (Nomad's
`PUT /v1/var/:path` replaces the whole object on the wire) and always
requires the caller's most recent `read/0`'s modify index — a stale value
is `{:error, %Error{kind: :conflict}}`, never a silent overwrite. This
boundary does not merge on the caller's behalf; a merge here would hide
exactly the concurrent-edit clobbering CAS exists to catch.

### 7. `read/0`'s `:not_found` *is* Data Export's enablement signal, not a separate probe

Nomad's `GET /v1/var/:path` 404s when the path has never been created.
`Http.read/0` lets `Nucleus.Nomad.Transport`'s `:not_found` mapping pass
straight through — `DEX-A01`'s "is Data Export enabled" check is exactly
this call, not a second status endpoint.

### Implementation-time correction: `Local`'s "not enabled" sentinel is `false`, not `null`

Not raised on the issue thread — the plan's own Decision 5 area asked for
two distinct signals from `Nucleus.NomadVars.Store.Local`: Nucleus itself
having no usable Nomad configuration (`:not_configured`) versus a specific
tenant not having Data Export enabled (`:not_found`, mirroring `Http`'s real
404). The plan's literal wording proposed the JSON literal `null` for the
second case, keyed on "a present key whose value is JSON null" being
distinct from "an absent key." It is not: `Nucleus.Backend.Seed.read/2` calls
`get_in/2` against the decoded document, which returns `nil` identically
whether the `"nomad_vars"` key is entirely absent from the seed document or
present with an explicit JSON `null` value — `get_in/2` cannot and does not
preserve that distinction once decoded. Every other `Local` implementation
in this codebase only needs one meaning for `nil` (`:not_configured`);
`:nomad_vars` is the first that needs two, and `null` cannot be one of them
through `Seed`'s existing API.

`false` resolves this without changing `Nucleus.Backend.Seed` itself: it
round-trips through `Seed.read/2` as the boolean `false`, distinguishably
non-`nil`, so `Nucleus.NomadVars.Store.Local` reads `nil` as `:not_configured`
(matching every other boundary's convention, unchanged) and `false` as
`:not_found`. `test/nucleus/nomad_vars/store/local_test.exs` proves the two
states behave differently from the same `Seed.write/2` call switched between
`nil` and `false`, per the plan's own "the two fixtures must be tested
separately" instruction — satisfied by a sentinel the plan did not specify,
not the one it did.

### 8. The `NOMAD_ADDR`/`NOMAD_TOKEN` runtime gate widens to an OR

`config/runtime.exs` required these two variables only when `:nomad_jobs`
resolved to its real implementation. Since `Nucleus.Nomad.Transport` is
shared, a deployment running `:nomad_vars` real while `:nomad_jobs` stayed
local would previously boot successfully and then have every `:nomad_vars`
call fail as `:not_configured` — the gate now fires when *either* boundary
resolves to real.

### Implementation-time correction: `Local`'s check-and-set was not actually atomic

Caught in review, not on the issue thread. The first pass of
`Nucleus.NomadVars.Store.Local.write/2` read the current section
(`Seed.read/1`), compared `expected_modify_index` against it in the caller's
own process, computed the new section, and only then called
`Seed.update/2` with a transform that ignored the value it was handed and
substituted the value already computed outside the `Agent`. `Seed.update/2`'s
atomicity guarantee — "a read-modify-write from two processes cannot
interleave" — only holds for a callback that actually reads the value it
receives; this one did not, so the guarantee did not apply. Two concurrent
writers presenting the same `expected_modify_index` both passed the check
and both succeeded, with the second silently overwriting the first — exactly
the outcome Decision 6 says check-and-set exists to prevent, and the
opposite of what the module's own moduledoc claimed. Confirmed by directly
running two overlapping writes against the same modify index before the fix
landed: both returned `{:ok, ...}`, no `:conflict`, and one write vanished.

Fixed by adding `Nucleus.Backend.Seed.get_and_update/3` — a new primitive,
alongside `read/2`/`write/3`/`update/3`, that runs `Agent.get_and_update/2`
under the hood: the callback receives the section's current value and
returns `{result, new_section}`, with both the CAS decision and the write
happening inside one `Agent` call. `write/2` now builds this callback
directly rather than composing a separate read, check, and write.
`Nucleus.Secrets.Store.Local` and `Nucleus.M2M.Clients.Local` needed no
equivalent fix — their writes are unconditional, so there is no decision to
make atomically with the write; plain `update/3`, with the whole
read-modify-write already inside its callback, was correct for both from the
start. `:nomad_vars` is the first local boundary with a genuine
check-and-set contract, which is what exposed the gap.
`test/nucleus/nomad_vars/store/local_test.exs` gained a regression test
that fires 20 concurrent writers at the same modify index and asserts
exactly one succeeds — confirmed to fail (2 successes instead of 1) against
the pre-fix implementation, and `test/nucleus/backend/seed_test.exs` gained
direct coverage of `get_and_update/3` itself, including a 50-writer
concurrent-increment test.

## Consequences

### Positive

- `Nucleus.Nomad.Transport` required no structural change to support a
  second boundary — exactly the "needs no assumption specific to jobs"
  guarantee `docs/adr/0022`'s Consequences section already claimed for it,
  now exercised rather than merely asserted.
- Every existing exhaustive `Error.kind()` case already had a generic
  fallback branch, so adding `:conflict` shipped with zero production-code
  edits outside `Nucleus.Backend.Error` itself — a genuine payoff of the
  discipline `docs/adr/0002` asked every prior boundary to keep.
- The `:not_configured`/`:not_found` distinction `Nucleus.NomadVars.Store.Local`
  now enforces gives DEX-S1 a real enablement signal to build against locally,
  with no Nomad ACL token required.
- `Nucleus.Backend.Seed.get_and_update/3` is now available to every boundary,
  not just `:nomad_vars` — the next boundary that needs an atomic
  check-and-set (or any other decide-then-write) against the shared seed has
  a primitive to reach for rather than reproducing this ticket's original
  bug.

### Negative

- **The first pass of `Nucleus.NomadVars.Store.Local.write/2` shipped a lost-update
  race** (see the Implementation-time correction above) — its own moduledoc
  claimed the exact guarantee the code did not provide. Caught in review
  before merge, not by any test that existed at the time; the regression
  test added alongside the fix is what makes this durable.

- **`Nucleus.Backend.Seed`'s `nil`-collapses-absence-and-null limitation is
  now load-bearing for one boundary's correctness**, worked around at the
  `Nucleus.NomadVars.Store.Local` layer rather than fixed at the source.
  A future boundary needing the same two-state distinction will hit this
  again and should either reuse the `false`-sentinel pattern or extend
  `Seed` itself — tracked in `living-notes.md`.
- **The `false` sentinel is this boundary's own convention, not a
  general `Seed` feature.** Nothing enforces it structurally; a future
  edit to `Nucleus.NomadVars.Store.Local` that pattern-matches `nil` before
  `false` (or vice versa in the wrong order) would silently collapse the
  two states again. The two describe-blocks in
  `test/nucleus/nomad_vars/store/local_test.exs` are what catch that
  regression, not the type system.

## Alternatives considered

**Extending `Nucleus.Backend.Seed` with a key-presence check (e.g. a
`has_section?/1`), to keep the plan's literal `null` sentinel.** Rejected —
`Seed` is shared, foundational infrastructure every other boundary already
depends on; widening its API to serve one boundary's one edge case is a
larger, riskier change than a local sentinel choice, and the ticket's own
scope note explicitly avoided adding a second seed file for this exact
distinction.

**Collapsing `:not_configured` and `:not_found` into one state for
`Nucleus.NomadVars.Store.Local`, matching what `Seed.read/2` can actually
tell apart.** Rejected — this is precisely the conflation Decision 5 exists
to prevent; DEX-S1's "not enabled" empty state and an ops misconfiguration
are different messages to different audiences (an end user vs. an
operator), and collapsing them here would push the distinction onto a
layer that has even less information to reconstruct it from.

**One `:nomad` boundary instead of `:nomad_jobs` + `:nomad_vars`.**
Rejected on the issue thread — see `docs/adr/0022` Decision 7, restated
here as binding on this ticket too.

## References

- EN-12 — [issue #72](https://github.com/dave-bell/nucleus/issues/72), the
  deciding issue, including the full implementation plan and its five
  resolved decisions
- `docs/adr/0002-backend-adapter-boundaries.md` — the behaviour/real-local
  shape, and the seventh-kind warning this ticket triggers
- `docs/adr/0003-shared-local-backend-seed.md` — `Nucleus.Backend.Seed`,
  whose `nil`-collapsing behaviour this ticket works around rather than
  changes, and which this ticket extends with `get_and_update/3` for the
  atomic check-and-set `write/2` needs
- `docs/adr/0007-secrets-store-adapter.md` — the read+write boundary shape,
  and the pure path/value-validator precedent `Nucleus.NomadVars.Path`/`Value`
  follow
- `docs/adr/0016-m2m-client-adapter.md` — `Nucleus.M2M.Purpose.validate/1`'s
  bare-reason-atom shape, mirrored by `Nucleus.NomadVars.Value.validate/1`
- `docs/adr/0022-nomad-jobs-adapter.md` — Decision 7, which named this
  boundary and its shared transport in advance, and Decision 8's
  async/budget pattern (not needed here — this boundary makes one request
  per call, no fan-out)
- `docs/requirements/Data-Export-Configuration.md` — `DEX-A01`–`A14`; this
  ticket claims none of them (`DEX-S1` through `DEX-S4` claim all fourteen)
- `docs/requirements/ADR-0006-Nomad-API-Authentication.md` (wiki,
  reference-only) — the static ACL token this adapter's `X-Nomad-Token`
  header reuses unchanged, and the `read`/`write` capability grant on the
  variables path this ticket's design assumes
- `lib/nucleus/nomad/transport.ex`, `lib/nucleus/nomad_jobs.ex` — EN-11's
  shared transport and boundary shape, extended here
- DEX-S1 (#73) through DEX-S4 (#76), and transitively DEX-S5 (#77), DEX-D1
  (#78), DEX-D2 (#79) — blocked by this ticket
