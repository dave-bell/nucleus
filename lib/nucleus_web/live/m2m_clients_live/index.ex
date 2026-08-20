defmodule NucleusWeb.M2MClientsLive.Index do
  @moduledoc """
  Lists the tenant's M2M clients (`M2M-A01`), with a create-first-client
  empty state (`M2M-A02`) — issue #35, M2M-S2.

  ## No URL params to gate — `mount/3`, not `handle_params/3`

  Unlike `NucleusWeb.SecretsLive`, this route carries no identifier (`/m2m/clients`,
  no `:environment`/`:client_id` segment) — there is nothing a `<.link
  patch={...}>` could change without a remount, so the initial (and only)
  fetch happens in `mount/3` directly. `NucleusWeb.M2MClientsLive.Show`
  (M2M-S3, #36) is the sibling route this ticket registers but does not
  implement — see its own moduledoc for why it, too, has no
  `handle_params/3`.

  ## One call to `Nucleus.M2M.list/1`, gate included

  `Nucleus.M2M.list/1` fails closed on `Nucleus.M2M.DenyList.suffixes/0`
  before ever calling the adapter, filters through the shared `visible?/1`
  predicate `Nucleus.M2M.fetch/2` also gates single-client reads with, and
  sorts deterministically (case-insensitive `client_name`, raw name
  tiebreak) — all in the context, not here. This module has nothing to
  filter or sort; it only renders what comes back.

  ## Every outcome gets its own assign and DOM id

  `Nucleus.M2M.list/1` can succeed or fail with any
  `Nucleus.Backend.Error.kinds/0` value — this `case` collapses them to
  three states via `NucleusWeb.M2MClientsLive.States`, mirroring
  `NucleusWeb.SecretsLive`'s exhaustive handling (`docs/adr/0010`):

  | Outcome | `:status` | DOM id |
  |---|---|---|
  | `{:ok, clients}` | `:ok` | `#m2m-clients-table` / `#m2m-clients-empty` |
  | `kind: :not_configured` | `:misconfigured` | `#m2m-clients-misconfigured` |
  | `kind: :unavailable` | `:unavailable` | `#m2m-clients-unavailable` |
  | `kind: :auth_expired` | `:auth_expired` | `#m2m-clients-auth-expired` |
  | anything else (`:not_found`, `:already_exists`, `:invalid` — none of
    which `list/1` has reason to return today) | `:unavailable` | `#m2m-clients-unavailable` |

  Every branch keeps the shell intact (`<Layouts.app>`, `#tenant-identifier`)
  so the user can navigate away — a crashed LiveView is not an acceptable
  rendering of any of these.

  ## `stream/3`, plus a separate count assign

  Streams are not enumerable (`AGENTS.md`), so `:client_count` — set
  alongside the stream, from the same `Nucleus.M2M.list/1` call, never
  recomputed separately — drives the empty-state branch. The create
  affordance (`#new-m2m-client-button`) sits *outside* the
  `@client_count == 0` conditional, always rendered whenever `@status ==
  :ok`, so it is present in both the empty and populated states
  (`M2M-A02`'s explicit requirement) without relying on the `hidden
  only:block` CSS trick `AGENTS.md` documents — that trick only works when
  the empty block is the stream comprehension's only sibling, which is not
  the case here once the create button is added.

  ## Row DOM ids are the client ID directly, not a hash

  Unlike `NucleusWeb.SecretsLive`'s ARN-hash (`docs/adr/0010`), `client_id`
  is already DOM-safe: `Nucleus.M2M.ClientId`'s allowlist is
  `[A-Za-z0-9_+]{1,128}`, anchored. `stream_configure(:clients, dom_id: &dom_id/1)`
  prefixes it (`"m2m-client-" <> client_id`) only to avoid an id starting
  with a digit; every row also carries `data-client-id={client.client_id}`
  so M2M-S3/S6 read the authoritative ID from an attribute rather than
  parsing it back out of the element id, matching the DOM-id contract in
  issue #35.

  ## No secret column, no mask, no reveal

  `Nucleus.M2M.Client` has no secret field — there is nothing here to mask
  or reveal, and `M2M-A03` (wiki) states the secret is only ever shown at
  creation or rotation. A masked placeholder column would imply a reveal
  that cannot exist.

  ## A `nil` `created_date` is an explicit state, not a blank cell

  `EN-10`/#33's Decision 6: a `Client` whose per-row `DescribeUserPoolClient`
  failed while listing carries `created_date_error` instead of
  `created_date`, and is still returned by `Nucleus.M2M.Clients.list_clients/0`
  — not dropped. The date cell renders `#m2m-client-date-unavailable-{id}`
  for that row rather than an empty string, so "the date failed to load" is
  visually distinct from "there was no date to begin with" (there is always
  a date; only reading it can fail).

  ## Placeholder create handler; the row control is a plain link

  This ticket renders `#new-m2m-client-button`; M2M-S4 (#37) implements it.
  `handle_event("new_client", ...)` just flashes "not yet implemented" so
  the button cannot crash the view in the meantime. The row's view control
  is `<.link navigate={~p"/m2m/clients/\#{client.client_id}"}>` — explicit
  `client_id` interpolation, not `~p"...\#{client}"`, since `Nucleus.M2M.Client`
  implements no `Phoenix.Param` — and needs no `handle_event` clause at all,
  since a `navigate` link has nothing to placeholder.

  `current_scope` and `environments` come from the `:authenticated`
  `live_session`'s `on_mount` hooks (`NucleusWeb.ScopeHook`,
  `NucleusWeb.EnvironmentsHook`), same order as `NucleusWeb.SecretsLive` —
  this module does not assign either itself.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.M2M
  alias Nucleus.M2M.Client
  alias NucleusWeb.M2MClientsLive.States

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:clients, dom_id: &dom_id/1)
      |> stream(:clients, [])
      |> fetch_clients()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("new_client", _params, socket) do
    {:noreply, put_flash(socket, :info, "Creating a client is not yet implemented.")}
  end

  @impl Phoenix.LiveView
  def handle_event("retry", _params, socket) do
    {:noreply, fetch_clients(socket)}
  end

  defp fetch_clients(socket) do
    case M2M.list(socket.assigns.current_scope) do
      {:ok, clients} ->
        socket
        |> assign(status: :ok, client_count: length(clients))
        |> stream(:clients, clients, reset: true)

      {:error, %Error{kind: :not_configured}} ->
        assign(socket, status: :misconfigured, client_count: 0)

      {:error, %Error{kind: :auth_expired}} ->
        assign(socket, status: :auth_expired, client_count: 0)

      {:error, %Error{}} ->
        assign(socket, status: :unavailable, client_count: 0)
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} environments={@environments}>
      <States.misconfigured :if={@status == :misconfigured} />
      <States.unavailable :if={@status == :unavailable} />
      <States.auth_expired :if={@status == :auth_expired} />

      <div :if={@status == :ok}>
        <div class="flex items-center justify-between gap-4 pb-4">
          <h1 class="text-lg font-semibold">M2M Clients</h1>
          <.button id="new-m2m-client-button" phx-click="new_client">New client</.button>
        </div>

        <.empty_state
          :if={@client_count == 0}
          id="m2m-clients-empty"
          icon="hero-inbox"
          message="No M2M clients yet."
        />

        <div :if={@client_count > 0} id="m2m-clients-table">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Client name</th>
                <th>Client ID</th>
                <th>Created</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody id="m2m-clients-table-body" phx-update="stream">
              <tr
                :for={{dom_id, client} <- @streams.clients}
                id={dom_id}
                data-client-id={client.client_id}
              >
                <td class="font-medium">{client.client_name}</td>
                <td class="font-mono text-sm">{client.client_id}</td>
                <td class="whitespace-nowrap">
                  <%= if client.created_date do %>
                    {format_created_date(client.created_date)}
                  <% else %>
                    <span
                      id={date_unavailable_id(client.client_id)}
                      class="text-base-content/50"
                    >
                      unavailable
                    </span>
                  <% end %>
                </td>
                <td class="text-right">
                  <.link
                    id={view_link_id(client.client_id)}
                    navigate={~p"/m2m/clients/#{client.client_id}"}
                    class="btn btn-sm"
                  >
                    View
                  </.link>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp dom_id(%Client{client_id: client_id}), do: "m2m-client-" <> client_id

  defp date_unavailable_id(client_id), do: "m2m-client-date-unavailable-" <> client_id

  defp view_link_id(client_id), do: "view-client-" <> client_id

  defp format_created_date(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end
end
