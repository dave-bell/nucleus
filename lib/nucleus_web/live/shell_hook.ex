defmodule NucleusWeb.ShellHook do
  @moduledoc """
  `on_mount` hook that assigns `:active_section` to every LiveView in the
  `:authenticated` `live_session`, for `NAV-A03`'s active-section
  highlighting.

  Attached via `live_session ..., on_mount: [{NucleusWeb.ScopeHook, :assign},
  {NucleusWeb.EnvironmentsHook, :assign}, {NucleusWeb.ShellHook, :assign}]`
  (`router.ex`) — registered third, after `ScopeHook` and `EnvironmentsHook`.
  That position is documentation, not a dependency: this hook reads only the
  connection URI, never `current_scope` or the sidebar's environment list,
  so it could run first or second with no behaviour change. Keep it after
  the two existing hooks so a future reader diffing the list sees only an
  addition, not a reorder.

  ## Why `attach_hook/4` on `:handle_params`, not plain `on_mount`

  A colocated JS hook reading `window.location.pathname` client-side was
  considered and rejected: it would be entirely invisible to
  `Phoenix.LiveViewTest`, leaving `NAV-A03` permanently unproven — the exact
  failure mode this ticket exists to fix (`docs/adr/0008-test-strategy.md`,
  no browser driver).

  Deriving `:active_section` once in `on_mount` itself, the way `ScopeHook`
  and `EnvironmentsHook` assign their own state, was also rejected:
  `docs/adr/0024-sidebar-expand-state-survives-navigation.md` documents that
  `<.link navigate={...}>` between routes on *different* LiveView modules
  remounts and reruns every `on_mount` hook, but `<.link patch={...}>` (and
  a `push_patch/2`) between routes handled by the *same* LiveView module —
  which does not apply to any of these six routes today, but would for a
  future `handle_params/3`-driven sub-view — changes `handle_params` without
  remounting. Deriving the active section from the URI inside `handle_params`
  itself, via `attach_hook/4`, covers both cases: a full remount runs
  `handle_params` too, and a same-module `patch` re-runs it without a
  remount that `on_mount` alone would miss.

  This is the second use of `attach_hook/4` in this codebase —
  `NucleusWeb.EnvironmentsHook` (`docs/adr/0023`) is the first, at the
  `:handle_event` lifecycle stage instead.

  ## Named `ShellHook`, not `ActiveSectionHook`

  `NAV-S3` (the identity menu) extends this same module with the user-menu
  open/close events, rather than stacking a fourth `on_mount` onto
  `docs/adr/0006`'s fixed order. `NucleusWeb.ActiveSection.for_path/1` stays
  the pure, independently unit-tested function this hook calls; `ShellHook`
  itself is the LiveView-lifecycle glue, named for the shell-level concerns
  it will grow to own, not for the one it happens to own first.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias NucleusWeb.ActiveSection

  @spec on_mount(:assign, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign, _params, _session, socket) do
    {:cont, attach_hook(socket, :active_section, :handle_params, &assign_active_section/3)}
  end

  defp assign_active_section(_params, uri, socket) do
    path = URI.parse(uri).path
    {:cont, assign(socket, :active_section, ActiveSection.for_path(path))}
  end
end
