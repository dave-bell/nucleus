# ADR-0034: Server-Driven Identity Menu via a Second `ShellHook` Event, and a Plain-`:browser` Logout Controller

## Status

Accepted — 2026-09-15

Decided on [NAV-S3](https://github.com/dave-bell/nucleus/issues/89). Builds on
`0032-active-section-highlighting-via-handle-params-attach-hook.md` (`NucleusWeb.ShellHook`, the
module this ticket extends, and the `attach_hook/4` precedent), `0024-sidebar-expand-state-survives-navigation.md`
(the ETS-backed pattern this ticket deliberately does *not* reuse), and
`0005-deferred-authentication.md` (why "logout" today can only drop a session, not end one).

## Context

`NAV-A08`'s pre-`NAV-D2` control (`layouts.ex`'s `#user-menu-panel`) was entirely client-side:
`phx-click={JS.toggle(...)}` to open, `phx-click-away`/`phx-window-keydown` both set to
`JS.hide(...)` to close, and the panel rendered unconditionally into the DOM with `class="hidden"`.
None of that reaches the server, so `Phoenix.LiveViewTest.has_element?/2` returned the same
answer whether the menu was open or closed — `NAV-A08`'s open/close/dismiss clauses were
permanently unprovable, not merely untested. Separately, `NAV-D2` narrowed `NAV-A08` itself: the
granted-scopes list is dropped, a Logout option is added. A `Plug.Conn` is also unavoidable for
any real logout — `Plug.Conn.configure_session/2` needs one, and a LiveView socket never has it
— so "Logout" cannot be a `handle_event` alone; it must end in a real HTTP request to a
controller.

## Decision

### Extend `NucleusWeb.ShellHook` with a second `attach_hook/4`, at `:handle_event`, rather than a new module or a fourth `on_mount`

`ShellHook` was named (and its moduledoc pre-announced, `docs/adr/0032`) for exactly this. The
existing `:active_section` hook runs at `:handle_params`; the new `:user_menu` hook runs at
`:handle_event`, mirroring `NucleusWeb.EnvironmentsHook.toggle_category/3`'s halt/fall-through
shape (`docs/adr/0023`) — two clauses that `{:halt, socket}` on the events it owns
(`"toggle-user-menu"`, `"close-user-menu"`), one fallthrough clause that `{:cont, socket}`s
everything else, so the four other LiveViews under the shell keep their own `handle_event/3`
clauses unaffected. This is the third `attach_hook/4` use in this codebase and the first time
one module owns two independent hooks at two different lifecycle stages.

### `:user_menu_open?` is a plain socket assign, not `SidebarNavState`-backed

`docs/adr/0024` put `:expanded_categories` behind a small ETS store keyed by `nav_session_id`
specifically because a sidebar child link's `navigate` always remounts, even to the same
LiveView module, wiping a plain assign. Nothing about the identity menu's own transitions
involves `navigate` — it opens and closes entirely within one mount, via `phx-click`,
`phx-click-away`, and `phx-window-keydown`. Reusing the ETS pattern here would solve a problem
this control doesn't have, at the cost of the menu surviving a page change it should not survive:
the menu closing when the user goes somewhere else is correct behaviour, not a bug. `on_mount`
assigns `false` once; the hook's two event clauses flip it thereafter.

### The panel is conditionally rendered, not merely CSS-hidden

`<div :if={@user_menu_open?} id="user-menu-panel" ...>` replaces the always-mounted
`class="hidden"` div. This is the change that actually makes `NAV-A08` provable:
`has_element?/2` now returns different answers before and after `"toggle-user-menu"`, closing
the exact gap the previous convention (`JS.toggle`/`JS.hide`) could never close.

### The `.dropdown` container also needs daisyUI's `dropdown-open` class — DOM presence alone is not visibility

`:if={@user_menu_open?}` correctly puts `#user-menu-panel` in the DOM when open and removes it
when closed, but daisyUI's own `.dropdown` CSS separately gates `.dropdown-content`'s
*visibility* on the container being `:focus-within` (or carrying `.dropdown-open`) —
independent of whether `.dropdown-content` exists in the DOM at all. The previous
`JS.toggle`/`JS.hide` convention never depended on this: it toggled the `hidden` Tailwind
utility directly, bypassing daisyUI's focus-driven mechanism entirely. Relying on
`:focus-within` after switching to a `phx-click` round-trip has no cross-browser guarantee — a
server round-trip is not what gives an element focus, and Safari does not focus a clicked
`<button>` at all, only a tabbed-to one. The fix threads the same `@user_menu_open?` assign onto
the `#user-menu` container's class list (`@user_menu_open? && "dropdown-open"`), so visibility
tracks the identical server state the DOM presence already tracks, with no dependency on focus
surviving a patch. Caught after the first pass shipped: tests using `has_element?/2` for
`#user-menu-panel`'s presence all passed, because the element genuinely is in the DOM — the gap
only shows up visually, which no `Phoenix.LiveViewTest` assertion checks by default. A
regression test now asserts `#user-menu.dropdown-open` directly, not just the panel's presence.

### `DELETE /logout` lives in the plain `:browser` pipeline, not `:assign_scope`/`:authenticated`

Logging out must work even in a request where scope assignment would otherwise fail — a
narrower, more defensive scope than the router's existing `:authenticated` `live_session`
requires. `NucleusWeb.SessionController.delete/2` only needs `fetch_session`, which `:browser`
already plugs; nothing in the action reads `current_scope`.

### `configure_session(drop: true)` is the entire session-clearing mechanic; no token revocation

`current_scope.token` is unconditionally `nil` under the disabled auth provider
(`docs/adr/0005`, `plugs/assign_scope.ex:45`) — there is no token to revoke, so there is nothing
for a real invalidation step to do yet. The observable effect today is narrower than "logged
out": the session cookie drops, `nav_session_id` resets (clearing `NAV-A05`'s per-session sidebar
expand state), and the very next request is immediately re-identified as the same dev user by
`NucleusWeb.Plugs.AssignScope`, since every request gets that identity unconditionally. The test
suite asserts exactly this boundary rather than simulating a "logged out" state that doesn't
exist yet — see `test/nucleus_web/controllers/session_controller_test.exs`.

### The scopes block is deleted from the template, not hidden or conditionally rendered

`NAV-D2` (`docs/adr/0006`'s wiki amendment) dropped `NAV-A08`'s granted-scopes clause outright,
with `AUTH-A11`'s companion clause struck to match. Removing the `<ul>`/"No scopes granted"
branch is a requirement-narrowing change landing here, not a stylistic simplification bundled
into this ticket.

## Consequences

### Positive

- `NAV-A08` is claimed and covered with real `@tag action:` tests — open/close via
  `render_click`, Escape dismissal via `render_keydown`, email and Logout presence once open, the
  scopes block's absence — `mix nucleus.trace --feature NAV` moves from 7/10 to 8/10; only
  `NAV-A09`/`NAV-A10` remain, both explicitly out of scope pending `NAV-S4`/`AUTH-A01`.
- `ShellHook` now demonstrates the exact multi-hook shape its own moduledoc predicted: one
  `on_mount` clause attaching two independent `attach_hook/4` calls at two different lifecycle
  stages, for two unrelated shell-chrome concerns, with no fourth `on_mount` entry and no second
  hook module.
- The click-away gap is recorded once, following the `SEC-A04`/`DEX-A11`/`APP-A02` partial-claim
  precedent (`test/README.md`), rather than either silently dropping the assertion or attempting
  a workaround hook the ticket explicitly ruled out.

### Negative

- **`ShellHook` now carries two genuinely unrelated responsibilities** (active-section
  highlighting, identity-menu open/close) in one module, the trade-off its own naming accepted in
  advance (`docs/adr/0032`). A third, unrelated shell-chrome event would need the same judgement
  call repeated: extend again, or finally split.
- **The true click-away dismissal stays permanently unprovable** at this test layer — only a real
  browser driver could drive a mouse click outside the element, and this repo has none
  (`docs/adr/0008`). Escape dismissal and every other `NAV-A08` clause are proven; click-away is
  not, and is recorded as such rather than claimed by proxy.
- **Logout's observable effect is narrower than the word implies** until `NAV-S4`/`AUTH-A01`
  land: the session drops, but the same dev identity reappears on the very next request. A
  reader expecting real sign-out from `DELETE /logout`'s name alone needs `docs/adr/0005` to
  understand why that's correct for now.

## Alternatives considered

**A colocated JS hook or client-only `JS.toggle`/`JS.hide` chain, kept as-is.** Rejected — this
is the status quo the ticket exists to fix: entirely invisible to `Phoenix.LiveViewTest`, the
same failure mode `docs/adr/0032` already rejected for active-section highlighting.

**A dedicated `UserMenuHook` module, separate from `ShellHook`.** Rejected — `ShellHook` was
named and documented in `docs/adr/0032` specifically to avoid this; a second module would leave
that moduledoc's own prediction unfulfilled for no structural benefit, and adds a fourth
`on_mount` entry to `docs/adr/0006`'s fixed order for a concern that fits an existing one.

**`SidebarNavState`-style ETS-backed state for `:user_menu_open?`.** Rejected — solves the
`navigate`-remount problem `docs/adr/0024` found for sidebar expand state, which the identity
menu's `phx-click`/`phx-click-away`/`phx-window-keydown`-only transitions never trigger. A plain
assign is simpler and correct here specifically because the menu closing on navigation is the
desired behaviour, not a defect to route around.

**Gating `/logout` behind `:assign_scope`/`:authenticated`.** Rejected — the ticket's own
plan is explicit that logout must work even if scope assignment would otherwise fail; the plain
`:browser` pipeline is the narrower, more defensive placement.

## References

- NAV-S3 (#89) — the deciding issue, including the full template/hook/controller plan
- `docs/adr/0032-active-section-highlighting-via-handle-params-attach-hook.md` — `ShellHook`'s
  first hook, and the moduledoc that pre-announced this ticket's extension
- `docs/adr/0023-sidebar-environment-grouping-and-category-toggle-state.md` — the `attach_hook/4`
  halt/fall-through shape this ticket's `toggle_user_menu/3` mirrors
- `docs/adr/0024-sidebar-expand-state-survives-navigation.md` — the ETS-backed pattern this
  ticket deliberately does not reuse, and why
- `docs/adr/0005-deferred-authentication.md` — why logout stops at `configure_session(drop: true)`
  rather than real token revocation
- `docs/adr/0006-application-shell-and-live-session-composition.md` — the `:browser`/
  `:assign_scope` pipeline split `/logout`'s placement relies on
- `lib/nucleus_web/live/shell_hook.ex`, `lib/nucleus_web/controllers/session_controller.ex`,
  `lib/nucleus_web/components/layouts.ex`, `lib/nucleus_web/router.ex`
- `test/nucleus_web/live/shell_test.exs`, `test/nucleus_web/controllers/session_controller_test.exs`,
  `test/README.md` (the click-away gap row)
- Wiki [Application Shell & Navigation](https://github.com/dave-bell/nucleus/wiki/Application-Shell-and-Navigation)
  (`NAV-A08`)
