defmodule NucleusWeb.EnvironmentsHook do
  @moduledoc """
  `on_mount` hook that assigns `:environments` — the sidebar's Environments
  section (`Layouts.app`) — to every LiveView in a `live_session`, the same
  way `NucleusWeb.ScopeHook` assigns `current_scope`.

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

  ## Archived environments are filtered here

  `Nucleus.TenantApi.list_environments/1` returns every environment,
  archived included (`ENV-A06`) — filtering is the caller's job, by design.
  This hook is that caller for the sidebar; `NAV-A04` requires archived ones
  stay hidden from it (while remaining reachable by direct URL, which this
  hook has no bearing on).

  Loaded via `Phoenix.LiveView.assign_async/3` so a slow tenant API does not
  block first paint. `assign_async/3` itself only spawns the fetch once the
  socket is connected — the disconnected static render just shows the
  loading state, no special-casing needed here.
  """

  import Phoenix.LiveView, only: [assign_async: 3]

  alias Nucleus.Scope
  alias Nucleus.TenantApi

  @spec on_mount(:assign, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:assign, _params, _session, socket) do
    token = scope_token(socket)

    socket =
      assign_async(socket, :environments, fn ->
        environments =
          case TenantApi.list_environments(token) do
            {:ok, environments} -> Enum.reject(environments, & &1.archived?)
            {:error, _reason} -> []
          end

        {:ok, %{environments: environments}}
      end)

    {:cont, socket}
  end

  defp scope_token(socket) do
    case socket.assigns[:current_scope] do
      %Scope{token: token} -> token
      _ -> nil
    end
  end
end
