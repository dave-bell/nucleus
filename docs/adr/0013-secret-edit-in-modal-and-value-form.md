# ADR-0013: Editing a Secret's Value In the Reveal Modal

## Status

Accepted — 2026-08-18

Decided on [SEC-S5](https://github.com/dave-bell/nucleus/issues/13). Builds on
`0012-secret-reveal-modal-and-icon-only-copy-affordances.md` (the single
`%Secret{}`/`nil` `:revealed` shape and the conditionally-rendered modal this
ticket edits inside of) and `0004-audit-emission.md` (the `secret_updated`
call site this ticket wires). Confirms, rather than reverses, ADR-0012's own
prediction of how this ticket would need to diverge from its original plan.

## Context

SEC-S5's plan (issue #13) was written against ADR-0011's `:revealed` shape —
a `%{key => Secret.t()}` map — and specified a row-level Edit control gated by
`handle_event("edit", %{"key" => key})` rejecting when `key` was absent from
that map. ADR-0012 landed first (`#43`) and replaced the map with a single
`%Secret{}` or `nil`, tied to one conditionally-rendered modal. ADR-0012's own
"Negative" consequences section already named the fix: gate on
`socket.assigns.revealed` being a `%Secret{}` whose `key` matches, and put the
edit affordance inside the modal rather than a row. This ADR is that fix,
plus three mechanics ADR-0012 flagged but did not settle: what "inside the
modal" means concretely, how a save button should behave, and how the
form itself is built — this is the first form this application has needed.

## Decision

### Edit swaps the modal's content in place; there is no second `<.modal>`

`:editing` (boolean) toggles which of two `~H` blocks renders inside the one
already-open `#secret-modal`: the existing value-display block, or a
`to_form/2`-built edit form. Both read `@revealed` for the key and the
original value; neither is its own `<.modal>`. This was chosen over stacking
a second modal specifically because of the `focusStack`/`JS.pop_focus/1`
gotcha ADR-0012 recorded as a risk for exactly this ticket: two conditionally
rendered modals open at once would have the inner one's dismissal consume the
outer one's saved focus. Swapping content in one modal never opens a second
one, so the gotcha does not need a fix — it does not arise.

### The reveal-before-edit gate matches `%Secret{key: ^key}`, not a boolean

`handle_event("edit", %{"key" => key}, socket)` and
`handle_event("save_edit", %{"key" => key, "secret" => params}, socket)` both
pattern-match `socket.assigns.revealed` against `%Secret{key: ^key}` and
reject anything else — including `nil`, and including a `%Secret{}` for a
*different* key. `:editing` (the UI toggle) is never consulted for the gate
itself; a client that dispatches `save_edit` directly, having never dispatched
`edit`, is rejected purely on the `revealed`/`key` match. This is the same
shape ADR-0011 and ADR-0012 both used for their own gates — checked in
`handle_event/3`, re-checked on every state-changing event, never trusted from
what the UI happens to render.

### `SEC-A07`'s re-masking is `:revealed` going to `nil`, not a separate step

A successful `save_edit` sets `:revealed` to `nil` (alongside `:editing` and
`:edit_form`). Because the modal is `:if={@revealed}` (ADR-0012), this single
assign removes the modal, the displayed value, and the edit form from the DOM
in the same step that confirms success — there is no second "now hide the
value" instruction to get wrong or forget. A failed save leaves `:revealed`
untouched, which is equally deliberate: `SEC-A08` requires the edit survive a
failure, and re-masking would close the form along with the value.

### Save starts disabled, and enables only once the value differs from the original

`edit_dirty?/2` compares the form's current `:value` field against
`@revealed.value` (the original, still held in `:revealed` while editing) and
drives the Save button's `disabled` attribute. This was a direct product
decision for this ticket, not derived from the plan's DOM id table, which
assumed a row-scoped control this design does not have. It is UI convenience
only — `handle_event("save_edit", ...)` re-validates and re-checks the gate
regardless of whether the browser ever sent a disabled click, the same
"hiding a button is not a gate" reasoning the plan itself insisted on for the
reveal-before-edit check.

### The value shape validator is `Nucleus.Secrets.Value`, shared with `SEC-S6`

`Nucleus.Secrets.Value.validate/1` checks non-empty and at most 4096
characters, via `String.length/1` — not `byte_size/1`, so a multi-byte value
is measured the way a person reading `SEC-A11`'s "live running count of
characters" would expect. It returns `Nucleus.Backend.Error.t()`, the same
shape every other validation step in `Nucleus.Secrets` returns, so
`Nucleus.Secrets.update/4`'s `with` chain needs no special case for a value
error. `SEC-S6` (issue #14, still `needs-decision`) is expected to reuse this
module unchanged for its own value field rather than writing a second copy.

### The edit form is an `embedded_schema` changeset, not a schemaless one

`NucleusWeb.SecretsLive.EditForm` is a tiny `embedded_schema` with one
`:value` field, whose `changeset/2` calls `Value.validate/1` through
`validate_change/3` so the inline error a user sees while typing and the
error `update/4` would return on submission are always the same text — one
message, defined once. A schemaless changeset (`{data, types}`) would have
worked structurally, but this application had no form before this ticket, and
`AGENTS.md`'s guideline names `embedded_schema`/`Ecto.Changeset` specifically;
this establishes the pattern `SEC-S6`'s creation form (key + value) is
expected to follow, rather than leaving the first form to set a precedent
nobody chose on purpose.

### `NucleusWeb.CoreComponents.button/1` gained `type` in its global attribute allowlist

The component's `attr :rest, :global, include: ~w(...)` list did not include
`type`, because no existing caller needed to override a `<button>`'s implicit
type inside a `<form>`. The Cancel button in the edit form does — an
un-typed `<button>` inside a `<form>` defaults to `type="submit"` in HTML5,
which would make Cancel submit the form it is meant to discard. Adding `type`
to the allowlist is additive and backward compatible; every existing call
site that omits it is unaffected.

## Consequences

### Positive

- No second modal, so ADR-0012's `focusStack` risk for this ticket is
  structurally avoided rather than mitigated.
- The reveal-before-edit gate is provable by direct event dispatch exactly
  the way ADR-0011's and ADR-0012's gates are — `render_click(view, "edit",
  ...)` and `render_click(view, "save_edit", ...)` without a prior reveal are
  both rejected, with no store mutation and no audit event, in
  `test/nucleus_web/live/secrets_live_test.exs`.
- `Nucleus.Secrets.Value` and `NucleusWeb.SecretsLive.EditForm` give `SEC-S6`
  a validator and a form pattern to reuse rather than invent.
- `SEC-A07`'s re-masking required no dedicated code path — confirming
  ADR-0012's own prediction that it would "come close to free" under the
  single-`Secret` shape.

### Negative

- The plan's DOM id table (`#edit-{row_id}`, `#secret-edit-form-{row_id}`,
  etc.) is not implemented as written — there is one edit form, not one per
  row, so the ids carry no row suffix (`#secret-edit-form`,
  `#secret-edit-value`, `#save-edit`, `#cancel-edit`, `#secret-edit-count`).
  A reviewer checking the plan literally against the code will find this ADR,
  not a row-suffixed id.
- `edit_dirty?/2`'s disabled-Save convenience has no server-side enforcement
  of its own beyond the gate that already exists — a determined client could
  submit an unchanged value and it would simply succeed as a no-op update
  (same value written back, a new `last_modified`, one more `secret_updated`
  audit record). No requirement asks this to be prevented, and Parameter
  Store's last-write-wins semantics make it harmless, but it is worth naming:
  the dirty-check is a nicety, not a second gate.
- `button/1`'s widened global attribute list is a shared component change
  riding in on a feature ticket, rather than its own isolated change — every
  future `<.button>` caller now silently gains the ability to pass `type`,
  which is desirable here but was not separately reviewed as a component API
  change.

## Alternatives considered

**A second `<.modal>` for editing, stacked over the reveal modal.** Rejected
— this is precisely the shape ADR-0012 warned would double-pop
`JS.pop_focus/1` against a module-global `focusStack`, consuming the outer
modal's saved focus. Content-swap-in-place avoids the interaction entirely
instead of fixing it.

**A row-level Edit button, as the original plan specified.** Rejected, per
ADR-0012's own "Negative" consequences: reveal state exists only while the
modal is open, so a row-level control would almost always hit the gate and
dead-end — a user who reveals, dismisses, and then clicks a row's Edit has
nothing left to edit against.

**A schemaless `Ecto.Changeset` (`{data, types}`) instead of an
`embedded_schema`.** Rejected — functionally equivalent for this one field,
but this is the first form in the codebase and `AGENTS.md` names
`embedded_schema` specifically; picking the schemaless shape here would leave
`SEC-S6` to either follow an unstated precedent or invent its own.

**Enforce the dirty-check server-side, rejecting a `save_edit` whose value
equals the original.** Rejected — no requirement asks for it, Parameter
Store's last-write-wins behavior (recorded as out of scope in the ticket
itself) makes a no-op update harmless, and rejecting it would add a rule a
future reader would have to reverse-engineer the reason for.

## References

- SEC-S5 (issue #13) — the deciding issue, including its own comment thread
  where the map-to-single-`Secret` mismatch was flagged before implementation
  began
- `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md` — the
  `:revealed` shape this ticket edits inside of, and the `focusStack` risk
  this ticket's content-swap design avoids
- `docs/adr/0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md`
  — the gate-in-`handle_event`/re-check-on-every-call shape this ticket's own
  gate follows
- `docs/adr/0004-audit-emission.md` — the `secret_updated` call site and the
  per-event field allowlist with no key named `value`
- `AGENTS.md` — `embedded_schema`/`Ecto.Changeset` for form validation with no
  database; `to_form/2` and `<.form for={@form}>` conventions
- `.opencode/context/project-intelligence/living-notes.md` — the Technical
  Debt entry this ADR resolves (SEC-S5's plan going stale under ADR-0012)
- SEC-S6 (issue #14, `needs-decision`) — expected to reuse
  `Nucleus.Secrets.Value` and the `embedded_schema` form pattern for its own
  key+value creation form
</content>
