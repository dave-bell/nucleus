defmodule NucleusWeb.EnvironmentsHook do
  @moduledoc """
  `on_mount` hook that assigns `:environments` and `:expanded_categories` —
  the sidebar's Environments section (`Layouts.app`) — to every LiveView in
  a `live_session`, the same way `NucleusWeb.ScopeHook` assigns
  `current_scope`.

  Attached via `live_session ..., on_mount: [{NucleusWeb.ScopeHook, :assign},
  {NucleusWeb.EnvironmentsHook, :assign}]`, in that order — this hook reads
  `current_scope.token` from the socket, so it must run after `ScopeHook`.
  The sidebar is shell chrome shared by every page under the shell
  (`NAV-A02`), not a per-page concern, so no individual LiveView (including
  the future `SecretsLive`) fetches its own copy.

  ## Failure degrades to empty, never surfaces as an error (`NAV-A07`)

  `Nucleus.TenantApi.list_environments/1` can fail
  (`{:error, Nucleus.Backend.Error.t()}`). This hook deliberately folds that
  into an empty list rather than exposing a `:failed`
  `Phoenix.LiveView.AsyncResult` state: `NAV-A07` and the wiki's error
  matrix require "the same empty state as no environments ... so navigation
  is never blocked." This is intentionally the opposite of Secrets' own
  fail-closed behaviour (`SEC-A17`) — the sidebar degrades, the secrets view
  refuses.

  ## Archived environments are no longer filtered here (`NAV-S1`)

  Before `NAV-S1`, this hook filtered `archived?` out of the list it
  assigned, because it was also the only place category grouping could have
  happened. `NucleusWeb.SidebarEnvironments.group/1` now owns both grouping
  *and* archived-exclusion — `NAV-A04`'s acceptance bar requires proving
  exclusion at that pure-function layer, unit-tested directly, without
  mounting a LiveView. This hook assigns every environment the tenant has,
  archived included; nothing outside `NucleusWeb.SidebarEnvironments` and
  `NucleusWeb.Layouts` reads `@environments`, so widening what it carries has
  no other caller to break.

  Loaded via `Phoenix.LiveView.assign_async/3` so a slow tenant API does not
  block first paint. `assign_async/3` itself only spawns the fetch once the
  socket is connected — the disconnected static render just shows the
  loading state, no special-casing needed here.

  ## Per-category expand/collapse state (`NAV-A05`)

  `:expanded_categories`, a `MapSet` of category slugs, is toggled by a
  `"toggle-category"` event handled here via `Phoenix.LiveView.attach_hook/4`
  rather than in each LiveView under the shell — `Layouts.app` is a function
  component rendered from four different LiveViews (`SecretsLive`,
  `EnvironmentsLive`, both `M2MClientsLive` views), and none of them should
  have to duplicate a handler for a shell-level concern they don't otherwise
  know about. The hook halts the `:handle_event` lifecycle stage for the one
  event it owns and falls through (`{:cont, socket}`) for every other event,
  so each LiveView's own `handle_event/3` clauses are unaffected.

  The state itself is not carried purely by the socket assign — see
  `NucleusWeb.SidebarNavState`'s moduledoc for why a plain assign cannot
  survive a sidebar child link's `navigate` (it always remounts, even to
  the same LiveView module, wiping any plain assign) and why the fix is a
  small ETS-backed store keyed by `nav_session_id`
  (`NucleusWeb.Plugs.AssignScope`), read here on every mount and written to
  on every toggle.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [assign_async: 3, attach_hook: 4]

  alias Nucleus.Scope
  alias Nucleus.TenantApi
  alias NucleusWeb.SidebarNavState

  @spec on_mount(:assign, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign, _params, session, socket) do
    token = scope_token(socket)
    nav_session_id = nav_session_id(session)

    socket =
      socket
      |> assign_async(:environments, fn ->
        environments =
          case TenantApi.list_environments(token) do
            {:ok, environments} -> environments
            {:error, _reason} -> []
          end

        {:ok, %{environments: environments}}
      end)
      |> assign(:nav_session_id, nav_session_id)
      |> assign(:expanded_categories, SidebarNavState.get(nav_session_id))
      |> attach_hook(:sidebar_environments, :handle_event, &toggle_category/3)

    {:cont, socket}
  end

  defp toggle_category("toggle-category", %{"category" => slug}, socket) do
    updated = SidebarNavState.toggle(socket.assigns.nav_session_id, slug)

    {:halt, assign(socket, :expanded_categories, updated)}
  end

  defp toggle_category(_event, _params, socket), do: {:cont, socket}

  defp scope_token(socket) do
    case socket.assigns[:current_scope] do
      %Scope{token: token} -> token
      _ -> nil
    end
  end

  # Falls back to a freshly generated id when the session predates
  # `NucleusWeb.Plugs.AssignScope` minting one (mirrors `NucleusWeb.ScopeHook`'s
  # own fallback for a session with no scope) — this id just won't be
  # stable across a later real remount from a fresh session in that edge
  # case, only for the lifetime of this one mount.
  defp nav_session_id(%{"nav_session_id" => id}) when is_binary(id), do: id
  defp nav_session_id(_session), do: Base.url_encode64(:crypto.strong_rand_bytes(16))
end
