# ADR-0029: Data Export Inline Edit — `update/5` Not `update/4`, Row-Scoped Forms Not a Modal, and `:conflict`'s Own Copy

## Status

Accepted — 2026-08-28

Decided on [DEX-S2](https://github.com/dave-bell/nucleus/issues/74). Builds on
`0027-nomad-vars-adapter.md` (`Nucleus.NomadVars.Store.write/2`'s
whole-map-replacement, CAS-enforced contract) and
`0028-data-export-listing-single-module-dom-ids-and-fetch-list-split.md`
(the `#var-{key}-value` cell this ticket edits inside of, and the
unhashed-key DOM-id convention this ticket's new ids extend). Follows
`0013-secret-edit-in-modal-and-value-form.md`'s form *mechanics*
(`embedded_schema` + `Ecto.Changeset`, `validate_change/3` delegating to a
shape validator, `to_form/2` wiring) without adopting its modal
choreography, per `DEX-A03`'s "this is configuration, not secret data."

## Context

DEX-A04/A05/A06 require inline edit, save, and cancel for every
configuration key except `env_names`, with a failed save that is never
silent. The issue's own plan specified the write function's contract, the
form mechanics to mirror, and the kind-to-copy mapping for a failed save —
but its literal `@spec` for the write function omitted a parameter its own
prose required, discovered only once the CAS contract it builds on
(`Nucleus.NomadVars.Store.write/2`) was read closely.

## Decision

### `Nucleus.NomadVars.update/5`, not `update/4` as the issue's `@spec` named it

The issue's plan gives `update/4 :: (key, value, expected_modify_index,
scope)`, but its own prose requires "building the new `Items` map" from
"the caller-supplied current items" without ever calling `Store.read/0` (a
fresh read-then-write would only catch a change that happened *during* the
save request, not the actual race — one that happened while the user had
the form open — `DEX-A06` and the wiki's concurrency row describe).
`Store.write/2` (DEX-S1/EN-12) replaces the *entire* `Items` map on the
wire; there is no way to assemble that map from only a key, a value, and an
index. `items` must be a parameter. Caught while implementing, not on the
issue thread — the plan's `@spec` simply undercounted its own arity by one.

`Nucleus.NomadVars.update/5(key, value, items, expected_modify_index,
scope)` takes the caller's own `items` map (`NucleusWeb.DataExportLive`
rebuilds it via `Map.new(socket.assigns.variables)`, since `@variables` is
a sorted list of tuples, not a map, per `docs/adr/0028`), replaces one key,
and writes the whole map back. `mix nucleus.trace` is unaffected — it keys
coverage off `@tag action: "..."` strings in tests, never function arity —
so this correction has no effect on requirement traceability, only on the
acceptance criteria's literal (and now corrected) function name.

### Row-scoped form swap inside `#var-{key}-value`, not a modal

Unlike `SecretsLive`'s reveal-then-edit modal, `DataExportLive` has no
reveal gate to begin with (`DEX-A03`: values are shown unmasked from the
first render) and no per-row detail view to host a modal's content. The
edit form swaps in place inside the same cell the value renders in,
conditioned on `@editing_key == key`, mirroring `SecretsLive.EditForm`'s
form *mechanics* — `embedded_schema`, `changeset/2` delegating to
`Nucleus.NomadVars.Value.validate/1` via `validate_change/3`, `to_form/2`
— without any of ADR-0013's modal-specific machinery (no `focusStack`
concern arises, because there is no second `<.modal>` to stack against
none).

At most one row is open at a time: `:editing_key` is a single key or `nil`,
not a set. Clicking "Edit" on a different row while one is already open
simply moves `:editing_key`, discarding whatever unsaved text was in the
row that closes — there is no cross-row unsaved-changes guard. No
requirement asks for one, and the alternative (a confirmation dialog, or
disabling every other row's Edit button while one is open) is unrequested
complexity for a low-stakes discard (the value was never sent anywhere).

### The server-side re-check pattern-matches, mirroring `SecretsLive`'s own gate

`handle_event("save_edit", %{"key" => key, ...}, socket)` pattern-matches
`socket.assigns.editing_key` against `^key` and rejects (flash, no adapter
call) on anything else — the same discipline
`SecretsLive.handle_event("save_edit", ...)` applies against a stale or
tampered `phx-value-key` (`secrets_live.ex:378-398`). A hidden or
disabled control is convenience; a client can dispatch `phx-click`/`phx-submit`
directly against the socket regardless of what is rendered, so this check,
not the UI, is the actual gate.

### `:conflict` gets its own copy; `edit_error_message/1` otherwise collapses to one generic retry message

Mirroring `SecretsLive.edit_error_message/1`'s shape
(`secrets_live.ex:898-916`): `:conflict` — "This value changed since you
loaded it. Reload to see the current value, then try again." — is kept
distinct because the correct next action genuinely differs from every other
kind (reload and re-attempt, not simply retry the same value against the
same stale index). `:not_found` gets its own defensive copy ("This key no
longer exists") though `write/2` operating on an existing map means it
should not normally occur. Every other kind (`:unavailable`,
`:not_configured`, `:auth_expired`, ...) collapses to one generic "can't
save this value right now, try again shortly" message — the same trade
`SecretsLive` already accepts for its own catch-all.

### `env_names` is rejected in `handle_event("edit", ...)` itself, not only by omitting its button

`handle_event("edit", %{"key" => "env_names"}, socket)` is its own clause,
returning the socket unchanged — a direct `render_click(view, "edit",
%{"key" => "env_names"})` (bypassing whatever the template renders) opens
no form, the same "hiding a button is not a gate" reasoning applied to a
key rather than to reveal state. DEX-S3/S4's picker is `env_names`'s only
edit path; this ticket's own inline form must never become a second one.

### `update/5` validates `value`'s shape itself, not only via the LiveView's changeset

Caught in review, after the first pass shipped: `update/5` called
`Store.write/2` directly with only an `is_binary/1` guard, trusting
`NucleusWeb.DataExportLive.EditForm`'s changeset — client-side, one
LiveView — as the only thing standing between an empty or 5000-character
value and the Nomad Variables store. Confirmed directly: `update/5` with
`value: ""` returned `{:ok, ...}` and wrote the empty string. This is
exactly the mistake `Nucleus.Secrets.update/4`'s own `with` chain
(`Key.validate/1`, `Value.validate/1`, *then* the store call,
`lib/nucleus/secrets.ex:222-237`) exists to prevent for its own boundary,
and it directly contradicted `EditForm`'s own moduledoc claim that "the
error `update/5` would enforce on submission" matches the inline one.

Fixed by adding `Nucleus.NomadVars.Value.validate/1` to `update/5`'s own
`with` chain, before `Store.write/2` — wrapping the bare `:empty`/`:too_long`
reason atom into `Nucleus.Backend.Error{kind: :invalid}` the same way
`Nucleus.M2M.create_client/2` wraps `Purpose.validate/1`'s own bare atom
(`lib/nucleus/m2m.ex:159,176-181`), which is exactly the division of labour
`Value`'s own moduledoc assigns to "a future `Nucleus.NomadVars` module."
Validation runs before the CAS check, so an invalid value is rejected even
against a stale index — there is no reason to consult Nomad's current
`ModifyIndex` for a write that will be rejected regardless of what it says.
`edit_error_message/1` gained a defensive `:invalid` clause ("That value
isn't valid.") for the case a client bypasses the LiveView's own changeset
gate directly.

## Consequences

### Positive

- `Nucleus.NomadVars.update/5`'s corrected arity is settled before DEX-S3/S4
  need to call it for `env_names`'s bulk update, rather than each
  discovering the same gap independently.
- No new `focusStack`/modal-stacking risk — `DataExportLive` has no modal at
  all, so ADR-0012's gotcha does not apply here by construction, not by
  mitigation.
- The kind-to-copy mapping and the server-side re-check both reuse
  `SecretsLive`'s already-reviewed shapes rather than inventing new ones.
- `update/5` now has the same defense-in-depth `Secrets.update/4` and
  `M2M.create_client/2` both give their own boundaries — DEX-S3/S4, a
  script, or a test calling it directly gets shape validation for free,
  not only whatever changeset happens to sit in front of it.

### Negative

- **The issue's acceptance criteria literally names `Nucleus.NomadVars.update/4`.**
  A reviewer checking the checklist item literally against the code will
  find `update/5` and this ADR, not a fifth positional argument silently
  folded into one of the other four.
- No cross-row unsaved-changes guard means switching which row is open
  silently discards unsaved text in the row that closes — acceptable here
  (nothing was ever sent to the server), but worth naming since a future
  reader might expect a confirmation prompt that does not exist.
- **The first pass of `update/5` shipped with no server-side value
  validation at all** — caught in review, not by any test that existed at
  the time (the LiveView's own changeset gate meant `mix test` was green
  throughout). The regression tests added alongside the fix
  (`test/nucleus/nomad_vars_test.exs`) are what make this durable, the same
  pattern `docs/adr/0027`'s own "Local's check-and-set was not actually
  atomic" correction followed.

## Alternatives considered

**Keeping `update/4` and having the LiveView call `Store.read/0` internally
before building the new map, so the context function's arity matches the
issue's `@spec`.** Rejected — this is exactly the fresh read-then-write the
issue's own plan says defeats CAS's purpose: it would only catch a change
that happened during the save request, not one that happened while the
user had the form open, which is the actual concurrent-edit case `DEX-A06`
exists for.

**A per-row modal, mirroring `SecretsLive` literally.** Rejected — `DEX-A03`
states values are not masked, so there is no reveal-gate reason for a
modal to exist in the first place; a modal here would add dismissal/focus
machinery with no problem for it to solve.

**Leaving value validation entirely to `NucleusWeb.DataExportLive.EditForm`'s
changeset, since `save_edit` already gates on `changeset.valid?` before
calling `update/5`.** Rejected once caught in review — the changeset gate
is client-code convenience, not a boundary guarantee; `update/5` is a
public context function, and DEX-S3/S4 (and any future caller) calling it
directly must not have to reconstruct the same changeset gate themselves
to get the shape guarantee `Value.validate/1` is supposed to provide.

## References

- DEX-S2 (issue #74) — the deciding issue, and the `@spec` gap this ADR
  corrects
- `docs/adr/0027-nomad-vars-adapter.md` — `Store.write/2`'s whole-map-replacement
  CAS contract that forces `update/5`'s arity
- `docs/adr/0028-data-export-listing-single-module-dom-ids-and-fetch-list-split.md`
  — the `#var-{key}-value` cell this ticket's form swaps inside of, and
  `@variables`'s sorted-list (not map) shape
- `docs/adr/0013-secret-edit-in-modal-and-value-form.md` — the form
  mechanics this ticket follows, explicitly without its modal choreography
- `lib/nucleus_web/live/secrets_live.ex:378-398` — the `save_edit`
  server-side re-check this ticket's own gate mirrors
- `lib/nucleus/secrets.ex:222-237` — `Secrets.update/4`'s `with` chain,
  the defense-in-depth pattern `update/5`'s validation fix follows
- `lib/nucleus/m2m.ex:159,176-181` — `M2M.create_client/2`'s
  bare-atom-to-`Error`-wrapping helper, mirrored by `update/5`'s own
  `validate_value/2`
- DEX-S3 (#75), DEX-S4 (#76) — expected to call `Nucleus.NomadVars.update/5`
  unchanged for `env_names`'s bulk update, swapping only the audit event at
  the call site
</content>
