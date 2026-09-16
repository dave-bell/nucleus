# ADR-0035: A `ghost` Variant on `<.button/1>`, Reserving Colour for Mutation Actions

## Status

Accepted — 2026-09-15

Decided as a direct UI correction on user report (#91) rather than a planned ticket — the M2M
client detail page's "Back to clients" link did not match its sibling "New client" button's size.
Builds on `<.button/1>` as introduced (undocumented decision, predates this ADR series) and its
existing `variant="primary"` case; does not touch `NucleusWeb.CoreComponents.copy_button/1`
(ADR-0012), which renders its own `btn-ghost` directly and has no `<.button/1>` dependency.

## Context

#91 reported that M2M client show's "Back to clients" control was a hand-built
`<.link class="btn btn-sm btn-ghost">`, sized `btn-sm` while the list page's "New client" button —
`<.button id="new-m2m-client-button" phx-click="new_client">New client</.button>` — rendered at
`<.button/1>`'s default size. The two sit in the same top-right corner position across sibling
pages (list vs. detail) and read as inconsistent because they are.

The environments detail page had the mirror problem in the other direction: "Manage Secrets" was
`<.link class="btn btn-primary">`, a solid, high-emphasis CTA, sitting in the same top-right
position as M2M's "New client" (a mutation action) and secrets' "New secret" (also mutation) —
but "Manage Secrets" navigates; it does not create or modify anything.

The issue named the fix directly: "Colour should be used to signal mutation actions ('new') from
navigation ('manage', 'back')." That is a real, reusable convention, not a one-off class fix — a
future top-right button needs a documented default rather than a fourth hand-built class string to
match by eye.

## Decision

### `<.button/1>` gains a `"ghost"` variant; navigation buttons move onto it

```elixir
attr :variant, :string, values: ~w(primary ghost)
```

`variants` maps `"ghost" => "btn-ghost"`, alongside the existing `"primary" => "btn-primary"` and
the no-variant default (`"btn-primary btn-soft"`, unchanged). No `size` attr was added — every
call site converted here (M2M's "Back to clients", environments' "Manage Secrets") wants the
component's plain `btn` default, matching "New client" and "New secret" exactly. `<.button/1>`'s
own `assign_new(assigns, :class, ...)` only fires when the caller supplies no `:class` at all, so
there is no supported way to layer a size modifier on top of a variant without a caller-supplied
`class` replacing the variant outright; that gap is deferred until a call site actually needs a
small navigation button, rather than speculatively built now.

### Both converted call sites drop their bespoke `class` string for `variant="ghost"`

- `NucleusWeb.M2MClientsLive.Show`: `<.link navigate={...} class="btn btn-sm btn-ghost">` becomes
  `<.button navigate={...} variant="ghost">`, losing `btn-sm` — intentionally, since the sibling
  "New client" button it must match carries no `btn-sm` either.
- `NucleusWeb.EnvironmentsLive`: `<.link navigate={...} class="btn btn-primary">` becomes
  `<.button navigate={...} variant="ghost">`, losing its primary colour — intentionally, per the
  issue's colour-signals-mutation rule.

`<.button/1>`'s moduledoc now states the rule directly ("Use `variant="ghost"` for navigation
actions ... so colour is reserved for signalling mutation actions") so the next top-right button
has a documented default instead of three prior examples to eyeball.

### Rejected: adding `size` now

A `size="sm"` attr was drafted and then reverted during implementation — it would have preserved
the *old* `btn-sm` sizing on M2M's back button, which is exactly the mismatch #91 reported. The
correct fix was matching the sibling button's size, not carrying the old size forward under a new
attr. No current call site needs a small `<.button/1>`; `copy_button/1`'s own `btn-sm` stays local
to that component (ADR-0012's icon-only affordance, a different sizing rationale entirely).

## Consequences

- Every top-right-corner button across M2M, secrets, and environments detail pages now shares one
  of two states: default-sized `btn-primary btn-soft` (or explicit `variant="primary"`) for
  mutation, `variant="ghost"` for navigation — no page-specific class string.
- `<.button/1>` still has no `size` attr. A future small navigation button (there is none today)
  will need one added deliberately, not a `class` override that silently drops `btn`/the variant
  class (see the `assign_new/3` mechanics above).
- `copy_button/1` is unaffected — it does not call `<.button/1>` and keeps its own `btn-sm
  btn-ghost` for icon-only affordances, a decision this ADR does not revisit.
