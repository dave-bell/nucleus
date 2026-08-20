defmodule NucleusWeb.M2MClientsLive.Show do
  @moduledoc """
  Stub for `/m2m/clients/:client_id` — M2M-S2 (#35) registers this route so
  `Index`'s per-row view link (`<.link navigate={~p"/m2m/clients/\#{client.client_id}"}>`)
  has somewhere real to land and the app compiles with both routes in place.
  M2M-S3 (#36) replaces this module's body wholesale — the gate,
  `Nucleus.M2M.fetch/2`, `m2m_client_viewed`, token-validity display — without
  touching the router or `NucleusWeb.M2MClientsLive.Index` (Decision 7).

  `mount/3`, not `handle_params/3`, per Decision 7: `Show` is reached only by
  a `live_navigate` from `Index` (a fresh remount on every `client_id`, never
  a `patch` between two client IDs), so there is nothing to re-validate on a
  patch that never happens — the same reasoning `phx.gen.live`'s own
  `Show.mount/3` follows (`deps/phoenix/priv/templates/phx.gen.live/show.ex.eex`).

  No gate, no `Nucleus.M2M.fetch/2` call, and no error-state handling belong
  in this ticket — only the shell, so `client_id` is not even read here yet.
  """

  use NucleusWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} environments={@environments}>
      <div id="m2m-client-detail-placeholder">
        M2M client detail is not implemented yet.
      </div>
    </Layouts.app>
    """
  end
end
