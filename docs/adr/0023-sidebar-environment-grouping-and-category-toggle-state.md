# ADR-0023: Sidebar Environment Grouping and Category Toggle State

## Status

Accepted — 2026-08-25

Decided on [NAV-S1](https://github.com/dave-bell/nucleus/issues/53). Builds on
`0006-application-shell-and-live-session-composition.md` (`NucleusWeb.EnvironmentsHook`,
`Layouts.app` as a stateless function component shared across LiveViews) and
`0008-test-strategy.md` (`Phoenix.LiveViewTest`/`PhoenixTest`, no browser driver).

## Context

`NAV-S1` replaced the flat, deliberately out-of-scope `#environments-list`
`layouts.ex` shipped as EN-7's stopgap (`docs/adr/0006`'s own scope note) with
category grouping, per-category counts, multi-category membership, and
independent expand/collapse (`NAV-A04`–`A07`, `ENV-A01`). The ticket's plan
named the grouping rules and the element-ID structure in full, but left two
questions open for implementation to settle: which module owns
archived-exclusion, and how per-category expand/collapse state is held given
`Layouts.app` is a function component, not a LiveView.

## Decision

### `NucleusWeb.SidebarEnvironments.group/1` owns archived-exclusion, not `EnvironmentsHook`

Before this ticket, `EnvironmentsHook` filtered `archived?` out of the list
it assigned, because it was also the only place grouping could have
happened. The ticket's acceptance criteria require the pure grouping
function's own unit tests to prove archived-exclusion directly, without
mounting a LiveView — the same "integration (mocked)" test layer both
`Application-Shell-and-Navigation.md` and `Environments.md` name for
"environment grouping/categorization logic." Filtering in the hook and
re-filtering in the pure function would satisfy that test bar too, but the
ticket's plan explicitly discouraged duplicating the filter and asked that
whichever module keeps it be documented. `group/1` now filters; the hook
assigns every environment the tenant has, archived included.
`@environments` is the only assign this widens, and nothing outside
`NucleusWeb.SidebarEnvironments` and `NucleusWeb.Layouts` reads it — the
other four LiveViews thread it through to `Layouts.app` but never inspect
its contents — so nothing else had a filtered-vs-unfiltered expectation to
break.

### Per-category expand/collapse state is a socket assign, toggled via `attach_hook/4`, not client-side `JS`

`layouts.ex`'s existing sidebar-wide collapse-to-icon-rail control
(`toggle_sidebar/1`) is a purely client-side `JS.toggle_attribute` chain —
the ticket's plan named this as one option to extend per-category. It was
rejected: `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md`
established that a control provable in `Phoenix.LiveViewTest` needs a plain
`phx-click="event"` server round-trip, since `render_click/1` can drive that
and not a `JS.exec`/`JS.toggle_attribute` chain with no server-visible state.
`NAV-A05` and `ENV-A01` are both `Test layer: e2e` in the wiki, and this repo
has no browser driver (`docs/adr/0008`) — proving them at all means routing
through `Phoenix.LiveViewTest`, which requires expand/collapse to be a real
assign the test can assert on before and after a `render_click/1`, not an
attribute toggle invisible to a server-rendered diff.

That assign needs to be reachable from every LiveView that renders
`Layouts.app` — currently `SecretsLive`, `EnvironmentsLive`, and both
`M2MClientsLive` views — without each one defining its own
`handle_event("toggle-category", ...)` for a shell-level concern it
otherwise has no reason to know about. `NucleusWeb.EnvironmentsHook`'s
`on_mount` now also calls `Phoenix.LiveView.attach_hook/4` for the
`:handle_event` lifecycle stage: it halts the lifecycle for
`"toggle-category"` (updating `:expanded_categories`, a `MapSet` of category
slugs, and returning `{:halt, socket}`) and falls through with
`{:cont, socket}` for every other event, so each LiveView's own
`handle_event/3` clauses are unaffected. This is the pattern
`Phoenix.LiveView`'s own documentation names for "sharing event handling
logic" across LiveViews via lifecycle hooks rather than a `LiveComponent` —
this is the first use of `attach_hook/4` in this codebase.

Each LiveView using `Layouts.app` passes `expanded_categories={@expanded_categories}`
explicitly, the same way it already threads `environments={@environments}`
through — `Layouts.app`'s `attr` default (`MapSet.new()`) only covers a
caller that has not wired the hook at all (mirroring `@environments`'
`nil`-default precedent for `test/support/scope_hook_demo_live.ex`).

### Categories start collapsed, and a collapsed category's environment list is not rendered at all

The ticket left the default expand/collapse state up to implementation,
recommending collapsed. Collapsed was chosen, matching typical sidebar
disclosure UX. More significantly: a collapsed category's `<ul>` of
environment links is not rendered in the DOM at all (`:if={category_expanded?(...)}`),
rather than rendered and hidden via a CSS class. This mirrors the
present-vs-painted distinction `core_components.ex`'s `<.modal>` moduledoc
already draws for exactly the same reason — `NAV-A05`'s wording ("expands to
reveal its environments as navigable links") is significantly easier to
prove as a real DOM transition (`refute has_element?/2` before, `assert
has_element?/2` after) than as a class-attribute check, and matches the
already-established test convention of asserting on a state attribute's
*value* (`aria-expanded`) rather than on visual hiding.

## Consequences

### Positive

- `NAV-A04`'s archived-exclusion, `NAV-A05`'s expand/collapse, `NAV-A06`'s
  navigation, and `ENV-A01`'s combined flow are all claimed with a real
  `@tag action:` and proven by `render_click/1`/`has_element?/2` — none of
  them needed a wiring-only partial claim like `SEC-A04`/`SEC-A13`.
- `attach_hook/4` for shared shell-level events is now a precedent any
  future `Layouts.app`-rendered control needing cross-LiveView state can
  reuse instead of inventing a new mechanism.
- `mix nucleus.trace --feature NAV` moves from 0/12 to 4/12; `--feature ENV`
  reaches 7/7.

### Negative

- **`EnvironmentsHook` now does two unrelated things**: fetch and assign the
  environment list, and own the `"toggle-category"` event handler. A future
  reader unfamiliar with `attach_hook/4` may not think to look in an
  `on_mount` hook for event-handling logic. The moduledoc says so
  explicitly to mitigate this.
- **`@environments` now carries archived environments**, a widening any
  future consumer of that assign must remember — a consumer reading it for
  anything other than rendering the sidebar (none exist today) would need
  its own archived filter.
- **Four call sites** (`SecretsLive`, `EnvironmentsLive`, both
  `M2MClientsLive` views) each needed a one-line addition
  (`expanded_categories={@expanded_categories}`) to `<Layouts.app>`. A fifth
  LiveView under the `:authenticated` `live_session` that forgets this line
  silently falls back to the `MapSet.new()` default — every category
  renders collapsed and un-collapsible from that view, not a crash.

## Alternatives considered

**Keeping `EnvironmentsHook` as the sole archived-filter, having `group/1`
trust its input.** Rejected — the ticket's acceptance criteria require
archived-exclusion be unit-tested directly at the pure-function layer, which
means the pure function must actually perform the exclusion, not assume a
caller already did.

**Client-side `JS.toggle_attribute`, extending `toggle_sidebar/1`'s
pattern.** Rejected — unobservable to `Phoenix.LiveViewTest`, which would
leave `NAV-A05`/`ENV-A01` as wiring-only partial claims (or entirely
unclaimed) rather than fully proven, despite there being no actual browser
API involved that would force that outcome the way `SEC-A02`/`M2M-A10`'s
gaps do.

**A `LiveComponent` wrapping each category's disclosure.** Rejected — the
codebase's own convention (`AGENTS.md`) is to avoid `LiveComponent`s absent a
strong specific need, and `attach_hook/4` gives the same "shared behaviour
without duplicating a handler" benefit without one.

**Moving grouping into `EnvironmentsHook` itself, assigning already-grouped
data as `@environments`.** Rejected, per the ticket's own instruction — the
existing `SecretsFlowTest` and other consumers expect `@environments` to
stay a flat, ungrouped list; grouping lives one layer downstream, in the
template/component layer, via the new pure function.

## References

- NAV-S1 — the deciding issue, including the full grouping-rules and
  element-ID plan
- `docs/adr/0006-application-shell-and-live-session-composition.md` —
  `EnvironmentsHook`'s original scope, `Layouts.app` as a stateless
  function component, the sidebar-degrades-vs-Secrets-fails-closed asymmetry
- `docs/adr/0008-test-strategy.md` — no browser driver; e2e-tagged
  requirements proven through `Phoenix.LiveViewTest`/`PhoenixTest` instead
- `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md` —
  the `phx-click="event"`-over-`JS.exec` convention this ticket follows for
  the same testability reason
- `lib/nucleus_web/live/sidebar_environments.ex`,
  `test/nucleus_web/live/sidebar_environments_test.exs`
- `lib/nucleus_web/live/environments_hook.ex` — the `attach_hook/4` addition
- Wiki [Application Shell & Navigation](https://github.com/dave-bell/nucleus/wiki/Application-Shell-and-Navigation)
  (`NAV-A04`–`A07`), [Environments](https://github.com/dave-bell/nucleus/wiki/Environments)
  (`ENV-A01`)
