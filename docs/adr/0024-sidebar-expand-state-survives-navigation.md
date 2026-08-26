# ADR-0024: Sidebar Expand/Collapse State Survives Navigation, via a Session-Keyed ETS Table

## Status

Accepted — 2026-08-25

Decided on [NAV-S1](https://github.com/dave-bell/nucleus/issues/53) — a correction found by manual
testing after `0023-sidebar-environment-grouping-and-category-toggle-state.md` landed on this
same branch, before this ticket's PR opened. Builds on `0023` (the `attach_hook/4`
`"toggle-category"` mechanism this ADR keeps unchanged) and `0005-deferred-authentication.md`
(`Nucleus.Scope`, `AUTH_ENABLED=false`, the single shared dev identity this ADR deliberately does
not key against).

## Context

`0023` made `:expanded_categories` a plain socket assign, reset to `MapSet.new()` in
`NucleusWeb.EnvironmentsHook.on_mount/4`. That ADR's own "Consequences" section did not surface a
problem with this, because every test written against it toggled and asserted within a single
mounted `view` — none of `NAV-A04`–`A07`'s acceptance criteria exercise a *navigation* in between.

Manually exercising the feature after `0023` merged surfaced a real defect: expanding a category,
then clicking one of its own child links, closed the category again — the child link is
`<.link navigate={...}>`, and `Phoenix.LiveView.push_navigate/2`'s own documentation is explicit
that `navigate` "will be shutdown and a new one will be mounted in its place," even when the
destination is the very same LiveView module with a different path param. There is no
special-casing for that case — `on_mount` reruns unconditionally, wiping the assign. Since every
sidebar child link targets `NucleusWeb.EnvironmentsLive` regardless of which page the click
originated from, this reset happened on effectively every child selection, not an edge case.

A `Plug.Session` cookie cannot fix this by itself: once a LiveView socket is connected, there is
no `Plug.Conn` for a `phx-click` handler to write a new cookie value back through — persisting a
toggle that way would need an actual HTTP round-trip (a redirect), defeating the reason a
socket-driven toggle was chosen in `0023` at all.

## Decision

### An ETS table, owned by a supervised `GenServer`, keyed by a session id — not by `Nucleus.Scope`/user identity

`NucleusWeb.SidebarNavState` (`lib/nucleus_web/live/sidebar_nav_state.ex`) is a `GenServer` added
to `Nucleus.Application`'s children whose `init/1` creates `:sidebar_expanded_categories`, a
`:protected`, named ETS table. `NucleusWeb.EnvironmentsHook.on_mount/4` reads it on every mount
(`SidebarNavState.get/1`) instead of always assigning an empty `MapSet`; the `"toggle-category"`
handler writes through it (`SidebarNavState.toggle/2`) instead of computing the new set itself.

The table is keyed by `nav_session_id` — a random id `NucleusWeb.Plugs.AssignScope` mints into the
session the first time a browser session has none, deliberately *not* derived from
`current_scope`. `AUTH_ENABLED=false` (the only mode that exists right now) means every request
resolves to the same dev identity; keying by identity today would collapse every open tab and
every dev session on the machine into one shared expand state. A random per-session id has no
dependency on identity at all, so it needs no rework once real auth ships and `current_scope`
starts carrying a real, distinct user per request.

### Reads bypass the `GenServer`; writes do not

The table is `:protected`, not `:public`: any process can read it directly via `:ets.lookup/2` —
`get/1` does exactly that, no message pass — but only its owning `GenServer` can write to it.
`get/1` runs on every mount (every navigation); `toggle/2` runs only when a user actually clicks a
category header, comparatively rare. Making the hot path (reads) bypass the process entirely
costs nothing; routing the cold path (writes) through `GenServer.call/2` buys real correctness
that a fully `:public` table with callers writing precomputed values would not have: two browser
tabs of the same session toggling the same category at nearly the same moment could otherwise both
read the same starting `MapSet`, compute independently, and the second write would silently
clobber the first. `toggle/2` sends the *intent* (`{:toggle, session_id, category_slug}`), and
`handle_call/3` performs the read-modify-write itself, single-threaded — the one thing a
fully-public table with precomputed writes cannot guarantee.

### No eviction, deliberately, for now

An entry is a `MapSet` of a handful of short category-slug strings — negligible memory even held
indefinitely — and there is currently no hook to remove an entry when its browser session's
cookie expires client-side. This is an accepted trade-off, not an oversight: revisit only if this
table's size is ever actually observed to matter, which the moduledoc says explicitly so a future
reader does not mistake the absence of a TTL for a bug.

### Multi-open stays exactly as `0023` decided

Considered and rejected in the same conversation that surfaced this defect: collapsing to a
single open category at a time (accordion-style) whenever a new one is opened. `0023`'s own
`NAV-A04` requirement already couples multi-category membership (one environment can belong to
several categories) with independent expand/collapse; forcing accordion behaviour would mean
opening category B could silently close category A even though the environment currently being
viewed also lives in A. No change made here.

## Consequences

### Positive

- The defect this ADR fixes is now a real regression test
  (`test/nucleus_web/live/shell_test.exs`, "a category stays expanded after selecting one of its
  children" and "a second category expanded before navigating is also still expanded after") —
  confirmed to fail against `0023`'s plain-assign implementation and pass against this one.
- `NucleusWeb.SidebarNavState` is this codebase's first process-owned ETS table and its first
  piece of state that survives a LiveView remount by design — a reusable pattern (and a
  reusable caution about read/write access shape) for any future shell-level control with the
  same "must survive `navigate`" requirement.
- `nav_session_id` is identity-independent, so it carries no migration cost when real
  authentication replaces `Nucleus.Scope.Provider.Disabled`.

### Negative

- **A new supervised process and a new session field**, for what started as a one-line-looking
  bug. `EnvironmentsHook`'s `on_mount` now depends on both `NucleusWeb.Plugs.AssignScope` (for
  `nav_session_id`) and `NucleusWeb.SidebarNavState` (for the table itself) — a fifth LiveView
  added under the `:authenticated` `live_session` that forgets nothing extra here, since both
  are wired at the `live_session`/`Application` level, not per-LiveView; the risk is `on_mount`
  itself gaining a third unrelated responsibility (environment fetch, `"toggle-category"` event
  handling, and now session-id resolution) that a future reader has to hold in mind at once.
- **`Phoenix.LiveViewTest`'s `follow_redirect/2` does not model a real browser's `navigate`
  faithfully enough to test this without extra care.** A real browser's `navigate` never repeats
  the `:assign_scope` plug — the session is fixed as of the socket's original HTTP page load,
  before the websocket connects, and stays fixed across every subsequent remount within that one
  connection. `follow_redirect/2` instead performs an entirely fresh, `ensure_recycled/1`'d HTTP
  request through the router for the destination LiveView, which re-runs `:assign_scope`. Cookie
  recycling only carries a session forward if the test's `conn` was already dispatched through
  the router at least once — the tests added by this ADR prime `conn` with a `get/2` before their
  first `live/2` call for exactly this reason; a test that skips that priming step will look like
  a fresh, session-less browser rather than a real navigate, and will not exercise this fix at
  all. This is a test-harness quirk, not a production behaviour gap — worth naming so a future
  test in this file does not silently pass for the wrong reason.
- **No eviction**, as already noted above.

## Alternatives considered

**Switch the sidebar's environment child links from `navigate` to `patch`.** Rejected as a
complete fix, though partially attractive: `patch` does not remount, so it would have preserved
the assign for free. But `patch` is only legal when the destination route is handled by the
LiveView already mounted — every sidebar child link targets `NucleusWeb.EnvironmentsLive`
regardless of origin, so this would only have helped when the user was already on
`EnvironmentsLive` navigating to a different environment; arriving from `SecretsLive` or either
`M2MClientsLive` view is inherently cross-module and `navigate` (and its remount) is unavoidable
there regardless. Solving only the same-LiveView case would also have required teaching
`Layouts.app` which LiveView is currently mounted, to pick `patch` vs `navigate` per link — more
plumbing than this ADR's fix, for strictly narrower coverage.

**Derive the expanded category from the currently-viewed environment's own category membership,
computed fresh on every mount, rather than persisting toggle history at all.** Rejected —
solves the specific complaint (the active environment's category reopens) but silently discards
any *other* category a user had manually opened before navigating, which a persistence-based fix
does not give up. Session-keyed persistence subsumes this option's benefit without its cost.

**Persist `:expanded_categories` in the `Plug.Session` cookie itself.** Rejected outright, not
merely as inferior: a LiveView socket has no `Plug.Conn` to write a new cookie value back through
once connected. The only way to persist a value into a cookie post-connect is a full HTTP
round-trip (e.g. a redirect), which defeats the reason `0023` chose a `phx-click` server round-trip
over client-side `JS` in the first place — the toggle would stop being a plain, single
`render_click/1`-provable event.

**A fully `:public` ETS table, writes via direct `:ets.insert/2` from any caller, `GenServer` only
for table lifecycle.** Rejected — it was this ADR's first draft. Reads dominate writes by a wide
margin here (every mount reads; only an explicit toggle click writes), so keeping reads
`GenServer`-free costs nothing either way; but letting writes bypass the `GenServer` reopens the
same-session concurrent-toggle lost-update race a serialized `handle_call/3` closes for free, for
no corresponding benefit.

## References

- NAV-S1 (#53) — the deciding issue; this ADR extends its own `0023`, landed on the same branch
  before this ticket's PR
- `docs/adr/0023-sidebar-environment-grouping-and-category-toggle-state.md` — the
  `attach_hook/4`/`"toggle-category"` mechanism this ADR builds on unchanged
- `docs/adr/0005-deferred-authentication.md` — why `nav_session_id` is identity-independent
- `lib/nucleus_web/live/sidebar_nav_state.ex` — the ETS table and `GenServer`
- `lib/nucleus_web/plugs/assign_scope.ex` — `nav_session_id` minting
- `lib/nucleus_web/live/environments_hook.ex` — the `on_mount`/`"toggle-category"` call sites
- `test/nucleus_web/live/sidebar_nav_state_test.exs`,
  `test/nucleus_web/live/shell_test.exs`, `test/nucleus_web/plugs/assign_scope_test.exs`
