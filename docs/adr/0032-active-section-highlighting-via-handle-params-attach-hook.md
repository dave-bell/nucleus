# ADR-0032: Active-Section Highlighting via a `:handle_params` `attach_hook`, and `/` as a Second Route on `ApplicationsLive`

## Status

Accepted — 2026-09-14

Decided on [NAV-S2](https://github.com/dave-bell/nucleus/issues/88). Builds on
`0006-application-shell-and-live-session-composition.md` (the `on_mount` composition order at
the `live_session` level) and `0023-sidebar-environment-grouping-and-category-toggle-state.md`
(the first use of `Phoenix.LiveView.attach_hook/4` in this codebase, at the `:handle_event`
lifecycle stage).

## Context

`NAV-A01`–`A03` were the last three actions in `Application-Shell-and-Navigation.md` with no
Phoenix surface at all: the application root (`/`) still served `phx.new`'s stock marketing
page through `PageController`, the tenant identifier already rendered unconditionally in the
header (a side effect of EN-7's shell work, not a dedicated ticket), and the sidebar's three
tenant-wide links (Applications, Data Export, M2M Clients) carried no DOM id and no way to tell
which one, if any, matched the currently-rendered view.

Two questions the issue's plan settled needed a real decision, not just wiring: how `/` reaches
`ApplicationsLive` without inventing a redirect hop, and how active-section state gets derived
and kept correct across every kind of navigation `Phoenix.LiveView` supports — a plain
`on_mount` assign, the same shape `ScopeHook` and `EnvironmentsHook` already use, looked like
the obvious fit until `docs/adr/0024`'s own findings were re-read.

## Decision

### `/` is a second route on `ApplicationsLive`'s existing `:index` action, not a redirect

Phoenix's router has no redirect macro. "Do this in the router" has exactly two forms available:
a tiny module plug issuing a 302, or serving the destination view directly at `/`. The second is
strictly simpler here — `live "/", ApplicationsLive, :index` sits beside the existing
`live "/applications", ApplicationsLive, :index` inside the same `live_session :authenticated`
block. No new module, no redirect hop, no second `mount/3` to keep in sync with the first. This
makes `/` and `/applications` both permanent, equally valid URLs for the same view — deliberate,
not a shortcut: `NAV-A01`'s `Then` clause is "the user is taken directly to the Applications
view," and serving it directly, with zero intermediate hop, is the most literal reading
available. `NucleusWeb.ActiveSection.for_path/1` treats both paths as `:applications`
accordingly — treating `/` as "no section" would have been a `NAV-A03` regression for the one
route this ticket exists to add.

### Active-section state is derived on every `:handle_params`, via a second `attach_hook/4`, not assigned once in `on_mount`

A colocated JS hook reading `window.location.pathname` client-side was considered first and
rejected outright: it would be entirely invisible to `Phoenix.LiveViewTest`, leaving `NAV-A03`
permanently unproven at any test layer — the exact gap this ticket exists to close, not one to
reproduce (`docs/adr/0008-test-strategy.md`, no browser driver).

Deriving `:active_section` once in `on_mount`, the same shape `NucleusWeb.ScopeHook` and
`NucleusWeb.EnvironmentsHook` already use for their own state, was the next candidate and was
also rejected, on re-reading `docs/adr/0024`'s own findings rather than assuming they didn't
apply here. `0024` established that `<.link navigate>` between different LiveView modules remounts
and reruns every `on_mount` hook — true today, since none of the six routed views currently
share a module with any other — but a `<.link patch>` (or `push_patch/2`) between two routes
handled by the *same* LiveView module changes `handle_params` without a remount, which
`on_mount` alone would not see rerun. No route today exercises that second case, but adding a new
`on_mount`-only hook now would have quietly baked in an assumption ("every relevant navigation is
a full remount") that `0024` had already disproven once, for a different piece of state, on this
same branch's own history. `NucleusWeb.ShellHook` instead calls `Phoenix.LiveView.attach_hook/4`
on the `:handle_params` stage — covering both a full remount (which also runs `handle_params`)
and a same-module `patch` in one mechanism, with no need to special-case either.

This is the second use of `attach_hook/4` in this codebase; `NucleusWeb.EnvironmentsHook`
(`docs/adr/0023`) is the first, at `:handle_event` instead. Registered third in the
`:authenticated` `live_session`'s `on_mount` list, after `ScopeHook` and `EnvironmentsHook` — a
position that is documentation, not a dependency: `ShellHook` reads only the connection URI via
`URI.parse(uri).path`, never `current_scope` or the sidebar's environment list, so it could run
first or second with no behaviour change. Kept last so a future reader diffing the list sees only
an addition, matching `docs/adr/0006`'s own "the router is the one place that shows the order
matters" framing — here, it explicitly doesn't, and the module doc says so.

### `NucleusWeb.ActiveSection.for_path/1` is a pure module; `NucleusWeb.ShellHook` is the LiveView glue that calls it

Mirrors `NucleusWeb.SidebarEnvironments.group/1`'s split: a pure function unit-tested directly,
with no LiveView mount required, plus a thin `on_mount`/`attach_hook` module that only wires it
into the lifecycle. `for_path/1` pattern-matches on `String.split(path, "/", trim: true)` rather
than a router-derived lookup, since the mapping is coarser than the six literal routes — both
`/environments/:environment` and its `/secrets` child collapse to the same `:environments`
result, and an unrecognized path falls through to `nil` rather than raising.

### Named `ShellHook`, not `ActiveSectionHook`

`NAV-S3` (the identity menu) is expected to extend this same module with the user-menu
open/close events, rather than stacking a fourth `on_mount` onto `docs/adr/0006`'s fixed order for
a second unrelated shell-chrome concern. Naming it for the lifecycle role it will grow into,
rather than the one behaviour it happens to own first, avoids an `ActiveSectionHook` rename
later purely because a second responsibility arrived.

### Viewing an environment highlights none of the three tenant-wide links, not the Environments section itself

`NAV-A03` names only the three tenant-wide items (Applications, Data Export, M2M Clients) as
needing a "visually distinguished as active" state. `for_path/1` resolves any environment path to
`:environments` specifically — not `nil` — so that value exists and is assigned, but nothing in
`layouts.ex` currently reads it: only the three tenant-wide links inspect `@active_section`, and
`:environments` matches none of them. This is deliberate scope discipline, not an oversight — the
ticket's own "Out of scope" section names highlighting the Environments sidebar section, or the
active environment's own child link, as future work. Resolving to `:environments` rather than
`nil` for these paths exists purely to prevent a *different* bug: without a distinct value,
whichever tenant-wide item was clicked last to reach the sidebar's Environments section would
stay highlighted after navigating into an environment, a stale-selection artifact `nil` alone
would not otherwise be distinguishable from "we don't have an opinion yet."

## Consequences

### Positive

- `NAV-A01`–`A03` are claimed and covered with real `@tag action:` tests, not a wiring-only
  partial claim — `mix nucleus.trace --feature NAV` moves from 4/10 to 7/10; only `A08`–`A10`
  (the identity menu, sign-out, and the unauthenticated redirect) remain, all named as `NAV-S3`/
  `NAV-S4` work.
- `attach_hook/4` on `:handle_params` is now a second precedent for shell-level state that must
  survive every kind of navigation a future ticket might introduce, alongside `0023`'s
  `:handle_event` precedent for shell-level events — together they cover the two lifecycle
  stages most likely to matter for the next shared-shell concern.
- `ShellHook`'s name anticipates `NAV-S3` without requiring `NAV-S3` to rename or restructure
  anything; it only adds handlers to an already-shell-scoped module.
- `/` and `/applications` sharing one module removes an entire class of future bug (a
  second `mount/3` implementation quietly drifting from the first) that a redirect-plug approach
  would have introduced instead.

### Negative

- **`NucleusWeb.ActiveSection.for_path/1` re-derives route shape by hand** (`String.split/3` plus
  pattern matching), rather than reading it from the router's own compiled route table. A future
  route rename must be updated in two places — `router.ex` and `active_section.ex` — with no
  compiler warning connecting them if one is missed; only a test failure would catch the drift,
  and only if that specific path is covered.
- **A third `on_mount` hook is now attached at the `live_session` level for every authenticated
  view**, regardless of whether that view's own template inspects `@active_section` at all —
  the same trade-off `docs/adr/0006`'s own "Negative" section already named for `EnvironmentsHook`,
  now repeated for a second hook. Cheap here (`URI.parse/1` on a string already in hand,
  no I/O), but the `on_mount` list is now three unrelated concerns a future fourth addition must
  reason about jointly.
- **`ShellHook`'s eventual identity-menu responsibilities (`NAV-S3`) are speculative**, named in
  this ADR and the module doc but not implemented here. If `NAV-S3` ends up needing a different
  lifecycle stage or a structurally different mechanism, this module's name will have anticipated
  a shape that didn't materialize — an acceptable bet given the alternative (a fourth `on_mount`
  entry) is the more expensive path to walk back.

## Alternatives considered

**A router-level redirect plug from `/` to `/applications`.** Rejected — Phoenix's router has no
redirect macro; a hand-rolled plug issuing a 302 is strictly more machinery than serving the same
module and action directly at both paths, for a worse literal reading of `NAV-A01`'s "taken
directly to" clause.

**A colocated JS hook reading `window.location.pathname` client-side for active-section
highlighting.** Rejected — entirely invisible to `Phoenix.LiveViewTest`, leaving `NAV-A03`
permanently unprovable at any test layer this repo has (`docs/adr/0008`, no browser driver).

**Deriving `:active_section` once in `on_mount`, the same shape as `ScopeHook`/`EnvironmentsHook`'s
own state.** Rejected — `docs/adr/0024` already found that a same-module `<.link patch>` changes
`handle_params` without remounting, which a value computed only in `on_mount` would not see
rerun. No route exercises that case today, but the fix that closes the gap now costs nothing
extra over the fix that would only work by coincidence.

**Naming the new module `ActiveSectionHook`.** Rejected — `NAV-S3` is expected to extend it with
unrelated identity-menu events; naming it for its first responsibility invites a rename later
purely because a second one arrived, the same naming lesson `docs/adr/0006` already applied to
distinguish `EnvironmentsHook`'s eventual name from a narrower "sidebar fetch" description.

## References

- NAV-S2 (#88) — the deciding issue, including the full router/hook/template plan
- `docs/adr/0006-application-shell-and-live-session-composition.md` — the fixed `on_mount` order
  this ticket extends to three hooks
- `docs/adr/0023-sidebar-environment-grouping-and-category-toggle-state.md` — the first
  `attach_hook/4` use, at `:handle_event`
- `docs/adr/0024-sidebar-expand-state-survives-navigation.md` — the `patch`-without-remount
  finding this ticket's `:handle_params` choice is a direct response to
- `docs/adr/0025-applications-listing-single-module-and-name-derived-dom-ids.md` — the
  single-module precedent `/` reuses rather than introducing a second `ApplicationsLive`-shaped
  module
- `lib/nucleus_web/live/active_section.ex`, `test/nucleus_web/live/active_section_test.exs`
- `lib/nucleus_web/live/shell_hook.ex`
- `lib/nucleus_web/router.ex`, `lib/nucleus_web/components/layouts.ex`
- Wiki [Application Shell & Navigation](https://github.com/dave-bell/nucleus/wiki/Application-Shell-and-Navigation)
  (`NAV-A01`–`A03`)
