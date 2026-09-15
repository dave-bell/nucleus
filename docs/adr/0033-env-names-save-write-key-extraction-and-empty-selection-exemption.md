# ADR-0033: `env_names` Save — `write_key/4` Extraction, `items` Not `current_value`, and the Empty-Selection Validation Exemption

## Status

Accepted — 2026-09-15

Decided on [DEX-S4](https://github.com/dave-bell/nucleus/issues/76). Builds on
`0029-data-export-inline-edit-update-arity-and-conflict-copy.md`
(`Nucleus.NomadVars.update/5`'s corrected arity and its
`Value.validate/1` integration) and `0027-nomad-vars-adapter.md`
(`Store.write/2`'s whole-map-replacement, CAS-enforced contract).
`0029`'s own References section predicted DEX-S4 would call `update/5`
"unchanged for `env_names`'s bulk update, swapping only the audit event
at the call site" — that did not happen; this ADR records why, and the
one validation gap the prediction's shape carried over unnoticed.

## Context

`DEX-A10`/`DEX-A11` require saving the environment picker's selection as
an explicit `env_names_updated` add/remove delta, and cancelling without
any write at all. The issue's own plan specified
`update_env_names/4 :: (new_names, expected_modify_index, current_value,
scope)` as a function calling straight through to DEX-S2's write path,
implying `update/5` itself would be reused with only the audit event
swapped. Both the signature and that implied reuse needed correcting
while implementing, and a further defect — env_names' own empty-selection
case failing validation — surfaced only during code review, after the
first pass had shipped and its own tests were green.

## Decision

### `write_key/4`, not `update/5` itself, is the shared part

`0029`'s prediction assumed one write function that could emit either
audit event depending on the caller. That was never actually true even
for `update/5` alone: it emits `nomad_var_updated` unconditionally, with
no parameter for a caller to opt out. Reusing `update/5` directly for
`env_names` would mean either adding a "which event to emit" parameter to
a function whose whole point is a fixed one-key-one-event contract, or
accepting a wrong audit event on every `env_names` save.

`write_key/4` is extracted instead — validate `value` via
`Value.validate/1`, then `Store.write/2` under CAS, with no audit side
effect of its own. `update/5` and `update_env_names/4` each call
`write_key/4` and then emit their *own* event: `nomad_var_updated`
(`details_allowed: [:path, :key]`) here, `env_names_updated`
(`details_allowed: [:path, :added, :removed]`) there
(`lib/nucleus/audit/event.ex:73-84`). Two events exist because `AUD-A04`
requires the audit trail to record which environments were specifically
added and removed for a set-based change, and `nomad_var_updated`'s
catalogue entry deliberately has no `value` field, so by extension no
room for a diff. Two call sites exist because two audit shapes exist —
not because two write paths exist; the write path is one function,
shared.

### `items`, not the issue plan's `current_value`

`Store.write/2` replaces the entire `Items` map on the wire — the same
fact `0029` established forces `update/5`'s `items` parameter. The issue
plan's `update_env_names/4` signature carries `current_value` (the raw
stored `env_names` string) instead of `items`, which omits exactly what
`write_key/4` needs to perform the write at all. Carrying both `items`
*and* a separately-supplied `current_value` would create two sources of
truth for the same fact, since `items` already contains whatever
`env_names` currently is (or does not contain the key at all, for a
tenant where it was never written). `update_env_names/4` takes `items`
alone and derives the current selection from it —
`Map.get(items, "env_names") |> EnvNames.parse/1` — the same reassembled
map `NucleusWeb.DataExportLive.save_edit/3` already passes to `update/5`.

### `env_names`' empty selection is exempted from `Value.validate/1`'s non-empty rule

Caught in review, after the first pass shipped with `mix precommit` green
and all planned tests passing: `update_env_names/4` serializes an empty
selection (`EnvNames.serialize([])`) to `""`, then routed through the same
`write_key/4` `update/5` uses — including `Value.validate/1`, which treats
any `""` as `{:error, :empty}`. Confirmed directly:
`NomadVars.update_env_names([], items, modify_index, scope)` returned
`{:error, %Error{kind: :invalid, details: %{reason: :empty, key:
"env_names"}}}`. This directly contradicted `Nucleus.NomadVars.EnvNames`'s
own moduledoc — "an empty selection is exactly `[]`, a perfectly valid and
representable choice (Data Export enabled for zero environments)" — and
was reachable through the picker's ordinary UI: deselect every
environment, click Save.

`Value.validate/1` is unchanged; it continues to enforce non-empty and
`@max_length` for every other key, and for any non-empty `env_names`
value. `write_key/4`'s private `validate_value/2` gained one additional
clause matched on `(@env_names_key, "")`, returning `:ok` before falling
through to the general `Value.validate/1` path — an exemption scoped to
this one key and this one value, not a change to what "valid" means for
variable values generally.

### `save_env_picker`'s nil-picker guard

Also caught in review: `"save_env_picker"` called
`EnvironmentPicker.selected_names/1` directly on `socket.assigns.env_picker`
with no nil check, unlike its `"toggle_env"`/`"filter_envs"` siblings in
the same handler block, both of which guard with
`case socket.assigns.env_picker do nil -> ... end` first. Not reachable
through ordinary clicking — the Save button only renders while the picker
is open, and `phx-disable-with` prevents a double-click race on the same
button — but a defensive consistency gap against the pattern the other
two handlers already establish. Given the same guard for consistency.

## Consequences

### Positive

- One write path (`write_key/4`) backs both `update/5` and
  `update_env_names/4`; a future third caller (a bulk-import script, a
  different LiveView) gets the same validate-then-CAS-write guarantee for
  free, regardless of which audit event it ultimately needs.
- `env_names`' empty-selection case is exercised at both the
  `Nucleus.NomadVars` unit level and end-to-end through the LiveView
  (deselect every environment, click Save) — the same "regression test is
  what makes a review-caught fix durable" pattern `0027` and `0029` both
  follow for their own review-time corrections.
- The `validate_value/2` exemption is scoped narrowly (one key, one
  value) rather than loosening `Value.validate/1` itself, so every other
  caller of `Value.validate/1` — today just `update/5` — keeps the
  non-empty guarantee unchanged.

### Negative

- **The issue's acceptance criteria literally names
  `update_env_names/4(new_names, expected_modify_index, current_value,
  scope)`.** A reviewer checking the checklist item literally against the
  code will find `update_env_names/4(new_names, items,
  expected_modify_index, scope)` and this ADR, not a `current_value`
  parameter folded elsewhere.
- **`0029`'s own References section predicted a simpler reuse** — calling
  `update/5` unchanged, swapping only the audit event. That prediction
  undercounted `update/5`'s own fixed one-event contract; a future reader
  of `0029` alone would expect a shape this ADR replaces.
- **The empty-selection validation gap shipped once, briefly** — the first
  pass's own test suite was green throughout, because no test exercised
  `update_env_names/4([], ...)` until review specifically asked whether a
  fully-deselected save had been tried. A future set-encoded key reusing
  `Value.validate/1` without checking whether its own "valid" allows `""`
  would reintroduce the same class of gap.

## Alternatives considered

**Adding a `key_for_audit`-style parameter to `update/5` so both call
sites share one function.** Rejected — `update/5`'s contract is
one-key-one-event by design (`0029`); parameterizing which event to emit
turns a five-argument function into six, for a distinction (`nomad_var_updated`
vs `env_names_updated`, scalar `key` vs list `added`/`removed`) that is
about audit *shape*, not about the write mechanics both events sit on top
of. Extracting the shared mechanics into `write_key/4` and letting each
public function own its own audit call is the narrower change.

**Carrying both `items` and the issue plan's `current_value` parameter,
using `current_value` only for the diff and `items` only for the write.**
Rejected — `items` already contains whatever `env_names` currently is (or
its absence), so a second, independently-supplied `current_value` is a
second source of truth for a fact `items` already carries, with no
guarantee the two agree if a caller ever passes them out of sync.

**Loosening `Value.validate/1` itself to accept `""`, rather than
carving out an exemption in `write_key/4`.** Rejected — `Value.validate/1`
backs `update/5`'s validation for every other key, where an empty value
remains genuinely invalid (`DEX-A05`'s edit form has no key for which an
empty save is meaningful). Loosening the shared validator to accommodate
one key's set-encoding convention would weaken the guarantee for every
other key that reuses it.

## References

- DEX-S4 (issue #76) — the deciding issue
- `docs/adr/0029-data-export-inline-edit-update-arity-and-conflict-copy.md`
  — `update/5`'s corrected arity, its `Value.validate/1` integration, and
  the "swapping only the audit event" prediction this ADR replaces
- `docs/adr/0027-nomad-vars-adapter.md` — `Store.write/2`'s
  whole-map-replacement CAS contract forcing both `update/5`'s and
  `update_env_names/4`'s `items` parameter
- `lib/nucleus/nomad_vars.ex:44-126` — the moduledoc sections recording
  each correction in place: "`update/5`, not `update/4`",
  "`update_env_names/4` shares this function's write, not its audit
  call", "`update_env_names/4`'s `items`, not the issue plan's
  `current_value`", "`update/5` validates `value`'s shape itself"
- `lib/nucleus/nomad_vars/env_names.ex` — `EnvNames`'s own moduledoc
  ("No `:unset`/`\"none\"` sentinel") establishing `[]` as a valid,
  representable selection, the basis for the validation exemption
- `lib/nucleus/audit/event.ex:73-84` — `nomad_var_updated`'s and
  `env_names_updated`'s distinct `details_allowed`/`details_required`
  shapes
</content>
