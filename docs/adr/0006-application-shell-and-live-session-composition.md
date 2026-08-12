# ADR-0006: Application Shell and Live Session Composition

## Status

Accepted — 2026-08-11

Decided on [EN-7](https://github.com/dave-bell/nucleus/issues/7). Builds on
`0002-backend-adapter-boundaries.md` (real/local `TenantApi`) and
`0005-deferred-authentication.md` (`Nucleus.Scope`, `NucleusWeb.ScopeHook`).

## Context

There was nowhere to reach or render Secrets: no `live` routes, no
`live_session`, a stock marketing layout, and a stock `core_components.ex`
with no modal, empty state, or copy affordance. The issue scoped this
tightly — only the frame required to reach Secrets, with the full
Application Shell & Navigation feature (`NAV-A01`–`A12`) left to its own
ticket — but three questions came up during implementation that the issue's
plan had not settled, plus one the issue itself flagged as a decision to
confirm.

## Decision

### daisyUI stays

The issue opened with a recommendation to remove daisyUI and hand-write
Tailwind components, reasoning that removal was cheapest while only two
files used it. That recommendation was accepted, then reversed mid-ticket
([comment](https://github.com/dave-bell/nucleus/issues/7#issuecomment-5259687096)):
`AGENTS.md` now reads *"Use daisyUI ... build on its component classes and
theme system rather than hand-rolling every primitive in plain Tailwind."`
`<.modal>`, `<.copy_button>`, `<.empty_state>`, `<.badge>`, and `<.card>` are
built on daisyUI's classes and theme tokens instead of plain Tailwind. This
is the binding decision going forward — later features should extend these
components' daisyUI-based styling, not reintroduce a hand-written parallel.

### `on_mount` hooks compose in sequence at the `live_session` level

`live_session :authenticated` runs `NucleusWeb.ScopeHook` then
`NucleusWeb.EnvironmentsHook` via `on_mount`. The issue's plan named only
`ScopeHook`. `EnvironmentsHook` was added because the sidebar's environment
list needs `assign_async/3`, which cannot run inside `Layouts.app` — a
stateless function component has no LiveView lifecycle to hook into.
`EnvironmentsHook` runs second because it reads `current_scope.token` off
the socket, which `ScopeHook` assigns first. Composing hooks in a fixed
order at the `live_session` level means every current and future view under
this session gets both the scope and the environment list without
individually opting in, and the router is the one place that shows the
order matters.

### The Secrets route ships now, behind a documented placeholder

The issue's plan preferred deferring the route entirely to SEC-S1, calling a
placeholder `SecretsLive` only a fallback. The fallback was required: the
sidebar's environment links use `~p` verified routes, which need a real,
compilable, navigable destination at compile time. There is no way to link
to a route that does not exist yet without either fabricating a fake path
(defeating the verified-route guarantee) or shipping a real one.
`NucleusWeb.SecretsLive` renders an explicit "not implemented" state via
`<.empty_state>` and is documented in-module as disposable once SEC-S1/SEC-S2
land — whoever picks up SEC-S1 replaces the module, not the route.

### The sidebar degrades on load failure; Secrets itself does not

The sidebar's environment list, loaded via `assign_async/3`, falls back to
the same `<.empty_state>` used for "no environments" on a load failure
(`NAV-A07`) — navigation must never be blocked by a slow or failing tenant
API. This is the opposite of Secrets' own fail-closed behaviour (`SEC-A17`),
where a load failure must refuse to render rather than degrade. Both are
correct for their own surface: the cost of a stale/empty sidebar is a missed
click, the cost of a degraded Secrets view is a wrong value read or written.
Future features composing both patterns in one view should keep them
separate per surface, not average them into one shared failure mode.

## Consequences

### Positive

- One binding answer on daisyUI ends the back-and-forth for every future
  component; `<.badge>` and `<.card>` (this ticket) and later additions
  build on daisyUI's tokens by default.
- The `on_mount` order (`ScopeHook` then `EnvironmentsHook`) is visible in
  exactly one place (the router), so a future third hook that reads
  `current_scope` knows where it must sit in the list.
- `SecretsLive`'s placeholder unblocks the route today without inventing
  fake data — it renders "not implemented," never a blank page or an error.

### Negative

- **`EnvironmentsHook` couples the shell to `Nucleus.TenantApi` at the
  `live_session` level.** Every view under `:authenticated`, not just ones
  that need the sidebar, now pays the cost of that `assign_async` fetch.
  Acceptable while there is exactly one view; worth revisiting if a future
  view under this session has no sidebar to render.
- **`SecretsLive` is a second, temporary source of truth for the Secrets
  route shape.** SEC-S1 must replace the module wholesale rather than patch
  it, or the placeholder's "not implemented" framing lingers past its
  purpose.
- **The sidebar/Secrets failure-mode asymmetry is not written down anywhere
  a future contributor would see it except this ADR and the two requirement
  actions (`NAV-A07`, `SEC-A17`) it reconciles.** A refactor that shares code
  between the two surfaces should re-read both actions, not just match the
  existing code's shape.

## Alternatives considered

**Deferring the Secrets route to SEC-S1, as the issue's plan preferred.**
Rejected. Verified routes need a compile-time destination; the sidebar
cannot link anywhere without one existing.

**Reading the environment list inside each LiveView that needs it, instead
of a shared `on_mount` hook.** Rejected. Every current and future
authenticated view renders the sidebar, so fetching once at the
`live_session` level avoids each view re-implementing the same
`assign_async` call and empty-state fallback.

**Making the sidebar fail closed, matching Secrets, for consistency.**
Rejected. `NAV-A07` is explicit that a failed load must not block
navigation; matching Secrets' fail-closed behaviour here would trade a
missed click for blocked access to every environment, a worse outcome for
a lower-stakes surface.

## References

- EN-7 — the deciding issue, including the full implementation plan and the
  daisyUI decision thread
- `docs/adr/0005-deferred-authentication.md` — `Nucleus.Scope`, `ScopeHook`,
  and the `on_mount`-at-`live_session`-level convention this builds on
- `docs/adr/0002-backend-adapter-boundaries.md` — `Nucleus.TenantApi`,
  the boundary `EnvironmentsHook` reads through
- `AGENTS.md` — current daisyUI guidance (post-reversal)
- Wiki [Application Shell & Navigation](https://github.com/dave-bell/nucleus/wiki/Application-Shell-and-Navigation)
  (`NAV-A01`–`A12`, only a subset implemented here — no `@tag action:` was
  claimed by this ticket's tests); [Secrets](https://github.com/dave-bell/nucleus/wiki/Secrets)
  `SEC-A17` (fail-closed) — reference for the failure-mode asymmetry
- Issue #9 (SEC-S1), Issue #10 (SEC-S2) — replace `NucleusWeb.SecretsLive`'s placeholder wholesale
