# ADR-0030: Environment Picker — `selected_count/1` Split from `selected_names/1`, and Fixed-Height List Panes

## Status

Accepted — 2026-09-11

Decided on [DEX-S3](https://github.com/dave-bell/nucleus/issues/75). Builds on
`0028-data-export-listing-single-module-dom-ids-and-fetch-list-split.md` (the
`#var-{key}-value` cell `env_names`'s own trigger sits inside) and
`0029-data-export-inline-edit-update-arity-and-conflict-copy.md` (`env_names`
rejected from `handle_event("edit", ...)` itself, this picker its only edit
path). `NucleusWeb.DataExportLive.EnvironmentPicker` follows
`lib/nucleus_web/live/m2m_clients_live/format.ex`'s precedent of a real
shared module, not a private helper, for state substantial enough to warrant
its own file and unit tests.

## Context

`DEX-A07`–`A09`'s plan specified `EnvironmentPicker`'s shape precisely —
`new/2`, `toggle/2`, `filter/2`, `selected_names/1`,
`available_matches/1`, `selected_matches/1` — and the LiveView calls that
built the picker's open/toggle/filter interaction exactly as drafted. Two
things the plan did not anticipate surfaced only once the picker was
actually exercised: the selection count badge disagreeing with what the
selected list renders, and how the two scrollable list panes should size
themselves as the environment count and the filter query both vary.

## Decision

### `selected_count/1`, a fourth accessor the plan did not name

The "Active (N)" badge (`#env-picker-selected-count`) initially read
`length(EnvironmentPicker.selected_names(picker))` — the same `selected`
`MapSet`'s raw size `DEX-A10`'s future save is meant to read. Caught in
review, not in the original plan: `env_names`'s stored value is
hand-edited, pre-Nucleus data (see `parse_env_names/1`'s own comment), so
`selected` can legitimately contain a short name absent from `all` — an
environment archived, renamed, or removed since that value was last
touched. `selected_matches/1`, which the "Active" list actually renders
from, filters `selected` down to `all`'s intersection first. A stale entry
therefore inflates the badge's count past the number of rows the same
modal shows underneath it, with nothing in the UI to explain the gap.

`selected_names/1` is not changed to filter against `all` — `DEX-A10` needs
the *raw* selection, stale entries included, since save must not silently
drop a stored value it can no longer otherwise account for just because
this ticket's picker happened to open while that environment was
unreachable. Filtering it here would fix the badge by breaking the save
contract the plan already committed to.

`selected_count/1` is a new function, added specifically for the badge:
the same `all`-intersection `selected_matches/1` computes, but ignoring
`filter` — the count must stay stable as the user types into the filter
field, exactly as `selected`/`available_matches` themselves stay
filter-independent by `DEX-A09`'s own design.

### `h-44` fixed, not `max-height`, on both list panes

Neither list pane's sizing was specified by the plan. `max-height` was
tried first: it bounds a long list's growth but not a short one's
shrinkage, so `DEX-A09`'s filter narrowing a list to one match shrank that
pane — and the modal around it — the moment matches dropped below five,
one column at a time, independent of the other. A fixed `h-44` with
`overflow-y-auto` on both `#env-picker-available` and `#env-picker-selected`
keeps the modal one constant size regardless of how many environments a
tenant has or how a filter narrows either side; only how much of each
box's fixed space is filled changes.

## Consequences

### Positive

- The badge and the "Active" list it labels can no longer visually
  disagree — both now derive from the same `all`-intersection, one with
  `filter` applied, one without.
- `DEX-A10`'s save is unaffected: `selected_names/1` still returns exactly
  what was selected, including any entry stale relative to `all`, so a
  future save cannot silently narrow `env_names` to only what a
  since-changed environment list happens to still recognize.
- The modal's footprint is stable across any tenant's environment count and
  any filter query — no layout jump as `DEX-A09`'s narrowing crosses the
  five-row threshold in either direction.

### Negative

- **A fourth accessor (`selected_count/1`) exists alongside three the plan
  named**, and it is easy to reach for `length(selected_names/1)` again
  without knowing why that reads wrong here — this ADR, and the doc comment
  on `selected_count/1` itself, are the record of why the two must not be
  merged.
- **A picker holding a stale selected short name still gives the user no
  way to see or clear it directly** — `selected_count/1` hides the
  discrepancy from the badge, but the phantom entry remains in `selected`
  until the next full toggle/save cycle touches it. Acceptable for this
  ticket (no save path exists yet to act on it), but a future ticket
  surfacing "N unrecognized selections" explicitly would need to read
  `selected_names/1` against `all`'s complement, not `selected_count/1`.
- Fixed-height panes leave visible empty space below a heavily filtered
  list rather than shrinking to fit — a deliberate trade against the
  modal-resize jitter `max-height` produced, not a constraint anyone asked
  for.

## Alternatives considered

**Filtering `selected_names/1` itself down to `all`'s intersection**,
matching what the badge would then trivially read. Rejected — `DEX-A10`'s
save reads this same function to compute `env_names`'s new value; filtering
it here would make a save silently drop any selection the picker's current
`all` doesn't recognize, which is exactly the kind of silent data loss this
codebase's failed-save handling (`docs/adr/0029`) was written to avoid for
the *write* path — doing it invisibly on the *read* side would be worse,
not better.

**`max-height` with a `min-height` floor**, to prevent the shrink-to-fit
jitter while still allowing growth. Not pursued — a floor tall enough to
stop single-row jitter is, in practice, close enough to the fixed height
this ADR chose that the extra CSS bought nothing a plain fixed height
didn't already give directly.

## References

- DEX-S3 (issue #75) — the deciding issue
- `docs/adr/0028-data-export-listing-single-module-dom-ids-and-fetch-list-split.md`
  — the `#var-{key}-value` cell `env_names`'s trigger extends
- `docs/adr/0029-data-export-inline-edit-update-arity-and-conflict-copy.md`
  — `env_names`'s rejection from the generic edit path, this picker its
  only door in
- `lib/nucleus_web/live/data_export_live/environment_picker.ex` —
  `selected_count/1`'s own doc comment states this same rationale inline
- `lib/nucleus_web/live/m2m_clients_live/format.ex` — the shared-module
  precedent `EnvironmentPicker` follows
- DEX-S4 (#76) — expected to call `selected_names/1` unchanged for the
  save delta; must not substitute `selected_count/1` for it
</content>
