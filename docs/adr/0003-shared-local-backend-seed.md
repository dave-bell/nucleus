# ADR-0003: Shared Local Backend Seed

## Status

Accepted — 2026-08-11

Decided on [EN-3](https://github.com/dave-bell/nucleus/issues/3). Builds on
`0002-backend-adapter-boundaries.md`.

## Context

`ADR-0002` established the real/local split per boundary, but deliberately left
open how a local implementation holds the state it pretends to own — there was
no boundary with real fixtures yet to decide it from. EN-3 needed five seeded
tenant-API environments (`prod`, `staging`, `dev`, `sandbox`, `legacy-qa`) to
give downstream tickets real data instead of each inventing its own. EN-4
(`:secrets`) needs the same thing next, and by design the seed file is one
document shared by both:

```json
{
  "tenant_api": { "environments": [...] },
  "secrets": { ... }
}
```

Two per-boundary state processes would each parse a JSON file, hold a decoded
map, and offer read/write access — the same machinery written twice. Worse, if
`:tenant_api` and `:secrets` each owned their own reader, the two tickets could
land in either order (as the issue requires) only by agreeing in advance which
one is allowed to define what "the seed file" means. A single owner sidesteps
that coordination entirely.

## Decision

One supervised `Agent`, `Nucleus.Backend.Seed`, **boundary-neutral** — it lives
in `Nucleus.Backend`, not inside `Nucleus.TenantApi` — parses
`priv/backends/local_seed.json` once in `init/1` and holds the decoded map as
its state for the life of the node. It exposes:

- `read/2` — the section for one boundary, or `nil` if the seed carries none
- `write/3` — replace a boundary's section wholesale
- `update/3` — replace a boundary's section with a function of its current
  value, atomically inside the `Agent`
- `reset/1` — re-parse the file, discarding every runtime mutation (test-only)

It is started **unconditionally** in `Nucleus.Application`'s supervision tree,
in every environment — not gated to `:dev`/`:test`.

An `Agent`, not a `GenServer` over an ETS table: a decoded JSON document is a
map that needs no table, and `Agent` is a `GenServer` specialised for exactly
"hold state, offer get/update from other processes."

A missing or undecodable file raises from `init/1`, bringing the node down at
boot. The file is checked in, so a parse failure is a packaging mistake, not a
runtime condition — every caller of `read/2` is spared having to consider one.

## Consequences

- **One seed owner, not one per boundary.** EN-4 reads its own `"secrets"`
  section through the same `Agent`, adds no new supervision-tree entry, and a
  section this module knows nothing about is served back unchanged — so
  `:tenant_api` and `:secrets` land in either order with neither redefining the
  file for the other.
- **Fault injection and test isolation share one lever.** `Seed.write/3` lets a
  local implementation's tests mutate seeded state directly; `Seed.reset/1` in
  `on_exit` undoes it, rather than each boundary inventing its own undo path.
- **Started in every environment, matching `ADR-0002`'s "local implementations
  ship regardless, never selected in production" model.** Gating the seed
  owner to `:dev`/`:test` would only add a "seed owner missing" branch for
  every reader to handle, for a case that already cannot be reached in
  production.
- **A single point of contention.** A bug in one boundary's seed handling
  (e.g. a stuck `Agent.update/2` call) now blocks every other local boundary
  reading through the same process, not just its own.
- **The API assumes "replace a section" or "transform a section."** A future
  boundary needing a different shape of local mutation — an append-only log,
  for instance — will have to extend `Seed`'s API rather than defining its own
  process. Worth revisiting if EN-4 or a later boundary needs one.

## Alternatives considered

**`GenServer` + ETS table (the original plan).** Rejected after review. ETS
outliving a crashed owner is a real property, but nothing here needs it — the
seed is read from a checked-in file, so a crash loses nothing an `Agent`
restart plus re-`init/1` wouldn't recover. An extra table to name and own
bought no benefit.

**One state process per boundary.** Rejected. Duplicates the same parse/hold/
read/write logic per boundary, and the seed file is already one shared
document — two owners would need a protocol for which one wins on a shape
disagreement, where one owner has none to negotiate.

**Read the file per call.** Rejected. Re-parses JSON on every call for no
reason, and cannot hold a runtime mutation between calls — fault injection and
any future test-time write need state that survives more than one call.

**Bake the seed in at compile time.** Rejected. A seed edit would require a
recompile, contradicting "checked-in fixtures editable without a rebuild."
Reading from `priv/` at runtime also matches how the path resolves inside a
release, not just a checkout.

**Gate the seed owner to `:dev`/`:test`.** Rejected. Local implementations
already ship in every release build per `ADR-0002`; a conditional child spec
adds a branch ("what if the boundary is `local` but the seed owner never
started?") for a case that is already unreachable in production.

## References

- [EN-3](https://github.com/dave-bell/nucleus/issues/3) — the deciding issue.
  The seed-loading mechanism was superseded twice in review comments: first
  from ad-hoc per-boundary loading to a supervised process, then from
  `GenServer` + ETS to an `Agent` started unconditionally in every environment.
- `docs/adr/0002-backend-adapter-boundaries.md` — the real/local split this
  builds on; local implementations shipping in every release regardless of
  selection is the premise "started everywhere" relies on.
- `docs/adr/0001-no-local-datastore.md` — the constraint `Seed` operates
  inside: in-memory per process, never persisted, reset on restart.
- [EN-4](https://github.com/dave-bell/nucleus/issues/4) — the next boundary to
  read its own section (`"secrets"`) of the same seed file.
