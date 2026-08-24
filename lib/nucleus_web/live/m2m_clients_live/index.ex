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

  ## Creation is a modal; `save_new_client` is M2M-S5's

  `M2M-S4` (#37) opens `#new-m2m-client-modal` and previews the exact name
  `Nucleus.M2M.ClientName.build/2` would produce. `M2M-S5` (#38, this
  ticket) replaces the placeholder flash with the real create call:
  `handle_event("save_new_client", ...)` re-validates the form server-side
  (a disabled submit button is UI convenience, not enforcement — the event
  can be dispatched directly with any params), then calls `Nucleus.M2M.create/4`,
  which itself re-validates `ticket_id`/`purpose`, builds the name, and
  rejects a reserved name (`M2M-A18`) — all before any adapter call.

  On success: the creation modal closes, the one-time credentials panel
  (`NucleusWeb.M2MClientsLive.CredentialsPanel`) opens holding the
  `Nucleus.M2M.ClientCredentials` this is the only place in the system that
  ever assigns, and the client list is **re-fetched** rather than
  `stream_insert/3`-ed at a computed position — the same choice
  `docs/adr/0014-secret-creation-key-consolidation-and-modal-exclusion.md`
  made for Secrets creation, for the same reason: re-deriving
  `Nucleus.M2M.list/1`'s case-insensitive sort/tiebreak a second time here
  risks the two drifting apart, where re-listing cannot drift because it
  *is* `list/1`. This also refreshes `:client_count`, which is what flips
  `#m2m-clients-empty` to `#m2m-clients-table` on a first client.

  On failure: a reserved name (`M2M-A18`) attaches a field error to
  `:purpose` (not a bare flash) rather than the generic format errors
  `M2M-S4`'s `phx-change` already shows, since the two need different copy
  and neither should be confused for the other. `:not_configured`,
  `:unavailable`, and `:auth_expired` render as `:create_error`, a banner
  above the modal's action row — mirroring `NucleusWeb.SecretsLive`'s
  `create_error_message/1` pattern exactly, including reusing this same
  module's own `:auth_expired`/`:misconfigured` page-level copy so the two
  states read consistently. Every branch keeps `@create_form` populated
  with what was submitted — a failure never discards entered values.

  ## The credentials panel and the creation modal are mutually exclusive

  Opening the creation modal (`"new_client"`) clears `:credentials` to
  `nil`, the same structural fix
  `docs/adr/0014-secret-creation-key-consolidation-and-modal-exclusion.md`
  applied to Secrets' own two conditionally-rendered modals: both this
  panel and `<.modal>` push onto the same module-global `focusStack`
  (`JS.push_focus/1`/`JS.pop_focus/1`), and having both mounted at once
  would double-pop it on whichever closes second. The panel has no
  backdrop-click or Escape dismissal of its own (see
  `CredentialsPanel`'s own moduledoc for why), so the only other way it
  closes is this deliberate one — a fresh "New client" click discards an
  unretrieved secret exactly as visibly as any other abandonment, never
  silently.

  The row's view control is `<.link navigate={~p"/m2m/clients/\#{client.client_id}"}>` —
  explicit `client_id` interpolation, not `~p"...\#{client}"`, since
  `Nucleus.M2M.Client` implements no `Phoenix.Param` — and needs no
  `handle_event` clause at all, since a `navigate` link has nothing to
  placeholder.

  `current_scope` and `environments` come from the `:authenticated`
  `live_session`'s `on_mount` hooks (`NucleusWeb.ScopeHook`,
  `NucleusWeb.EnvironmentsHook`), same order as `NucleusWeb.SecretsLive` —
  this module does not assign either itself.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.M2M
  alias Nucleus.M2M.Client
  alias Nucleus.M2M.ClientName
  alias Nucleus.M2M.NewClient
  alias NucleusWeb.M2MClientsLive.CredentialsPanel
  alias NucleusWeb.M2MClientsLive.Format
  alias NucleusWeb.M2MClientsLive.States

  @reserved_name_message "this name is reserved for internal system use — choose a different purpose"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:clients, dom_id: &dom_id/1)
      |> stream(:clients, [])
      |> assign(:creating, false)
      |> assign(:create_form, nil)
      |> assign(:name_preview, nil)
      |> assign(:create_error, nil)
      |> assign(:credentials, nil)
      |> fetch_clients()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("new_client", _params, socket) do
    form = build_create_form()

    socket =
      socket
      |> assign(:creating, true)
      |> assign(:create_form, form)
      |> assign(:name_preview, preview_name(form.source))
      |> assign(:create_error, nil)
      # Mutual exclusion with the credentials panel — see the moduledoc's
      # "The credentials panel and the creation modal are mutually
      # exclusive" section.
      |> assign(:credentials, nil)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate_new_client", %{"new_client" => params}, socket) do
    changeset =
      %NewClient{}
      |> NewClient.changeset(params)
      |> Map.put(:action, :validate)

    socket =
      socket
      |> assign(:create_form, to_form(changeset, as: :new_client))
      |> assign(:name_preview, preview_name(changeset))

    {:noreply, socket}
  end

  # `M2M-A08`/`M2M-A18` — server-side, always: a disabled submit button is
  # UI convenience only, and this event can be dispatched directly with any
  # params, bypassing whatever `validate_new_client` already rejected
  # client-side (`M2M-A05`/`A06`'s own server-side enforcement claim). See
  # the moduledoc's "Creation is a modal" section.
  @impl Phoenix.LiveView
  def handle_event("save_new_client", %{"new_client" => params}, socket) do
    changeset =
      %NewClient{}
      |> NewClient.changeset(params)
      |> Map.put(:action, :validate)

    if changeset.valid? do
      create_client(socket, changeset)
    else
      socket =
        socket
        |> assign(:create_form, to_form(changeset, as: :new_client))
        |> assign(:name_preview, preview_name(changeset))

      {:noreply, socket}
    end
  end

  # A `save_new_client` dispatched with no `"new_client"` key at all (a
  # hand-crafted event, not anything the real form ever sends) — treated as
  # an empty submission rather than left unmatched, so a malformed direct
  # dispatch cannot crash the LiveView either.
  @impl Phoenix.LiveView
  def handle_event("save_new_client", _params, socket) do
    handle_event("save_new_client", %{"new_client" => %{}}, socket)
  end

  # Every dismissal route the modal offers — X, Escape, backdrop, and the
  # Cancel button — arrives here, carrying no params.
  @impl Phoenix.LiveView
  def handle_event("cancel_new_client", _params, socket) do
    socket =
      socket
      |> assign(:creating, false)
      |> assign(:create_form, nil)
      |> assign(:name_preview, nil)
      |> assign(:create_error, nil)

    {:noreply, socket}
  end

  # The credentials panel's own, sole dismissal route — see
  # `CredentialsPanel`'s moduledoc for why it has no other. Once this runs,
  # the secret is gone from both the rendered HTML and this socket's
  # assigns — there is no way back to it, by design (`M2M-A08`'s error
  # matrix: the only recovery past this point is rotation).
  @impl Phoenix.LiveView
  def handle_event("dismiss_credentials", _params, socket) do
    {:noreply, assign(socket, :credentials, nil)}
  end

  @impl Phoenix.LiveView
  def handle_event("retry", _params, socket) do
    {:noreply, fetch_clients(socket)}
  end

  # `M2M-A08`'s success path, plus every `Nucleus.Backend.Error.kinds/0`
  # failure — see the moduledoc's "Creation is a modal" section for the
  # reasoning behind each branch.
  defp create_client(socket, changeset) do
    ticket_id = Ecto.Changeset.get_field(changeset, :ticket_id)
    purpose = Ecto.Changeset.get_field(changeset, :purpose)
    minutes = Ecto.Changeset.get_field(changeset, :access_token_validity_minutes)

    case M2M.create(ticket_id, purpose, minutes, socket.assigns.current_scope) do
      {:ok, credentials} ->
        socket =
          socket
          |> assign(:creating, false)
          |> assign(:create_form, nil)
          |> assign(:name_preview, nil)
          |> assign(:create_error, nil)
          |> assign(:credentials, credentials)
          # `M2M-A08`: the new client appears in the list, in sort
          # position, and `:client_count` flips the empty state — see the
          # moduledoc for why this re-lists rather than computing a stream
          # insertion position.
          |> fetch_clients()

        {:noreply, socket}

      {:error, %Error{kind: :invalid, details: %{reason: :reserved_name}}} ->
        {:noreply, attach_form_error(socket, changeset, :purpose, @reserved_name_message)}

      {:error, %Error{kind: :invalid, details: %{field: field}}}
      when field in [:ticket_id, :purpose] ->
        {:noreply, attach_form_error(socket, changeset, field, "isn't valid")}

      {:error, %Error{kind: :invalid}} ->
        {:noreply,
         attach_form_error(
           socket,
           changeset,
           :access_token_validity_minutes,
           "must be a whole number of minutes from 5 to 60 inclusive"
         )}

      {:error, %Error{} = error} ->
        # `:not_found`/`:already_exists` are not reachable from
        # `Nucleus.M2M.create/4` today — folded into the same generic copy
        # as `:unavailable` so no `Nucleus.Backend.Error.kinds/0` value can
        # crash this LiveView, matching `NucleusWeb.SecretsLive`'s own
        # exhaustive fallback. `:create_form` is still reassigned from the
        # submitted changeset — a failure must never discard entered
        # values, on this branch any more than the field-error branches
        # above.
        socket =
          socket
          |> assign(:create_form, to_form(changeset, as: :new_client))
          |> assign(:create_error, create_error_message(error))

        {:noreply, socket}
    end
  end

  defp attach_form_error(socket, changeset, field, message) do
    changeset =
      changeset
      |> Ecto.Changeset.add_error(field, message)
      |> Map.put(:action, :validate)

    assign(socket, :create_form, to_form(changeset, as: :new_client))
  end

  defp create_error_message(%Error{kind: :not_configured}) do
    "M2M Clients isn't configured yet. This is an operations issue, not something you can fix here."
  end

  defp create_error_message(%Error{kind: :auth_expired}) do
    "M2M clients can't be reached right now."
  end

  defp create_error_message(%Error{}) do
    "Can't create this client right now. Try again shortly."
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
                    {Format.created_date(client.created_date)}
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

        <%!--
        Only in the DOM while it is open, mirroring `NucleusWeb.SecretsLive`'s
        create modal — see the moduledoc's "Creation is a modal" section.
        --%>
        <.modal
          :if={@creating}
          id="new-m2m-client-modal"
          show
          on_cancel={JS.push("cancel_new_client")}
        >
          <:title>New M2M client</:title>
          <.form
            for={@create_form}
            id="new-m2m-client-form"
            phx-change="validate_new_client"
            phx-submit="save_new_client"
          >
            <.input
              field={@create_form[:ticket_id]}
              id="new-m2m-client-ticket-id"
              type="text"
              label="Ticket ID"
              placeholder="OPS-1234"
              class="w-full input font-mono text-sm"
            />
            <p class="text-xs text-base-content/70 -mt-1 mb-2">
              Jira ticket ID, e.g. <code>OPS-1234</code>.
            </p>

            <.input
              field={@create_form[:purpose]}
              id="new-m2m-client-purpose"
              type="text"
              label="Purpose"
              placeholder="nightly-sync"
              class="w-full input font-mono text-sm"
            />
            <p class="text-xs text-base-content/70 -mt-1 mb-2">
              Short, dash-separated description, e.g. <code>nightly-sync</code>.
            </p>

            <.input
              field={@create_form[:access_token_validity_minutes]}
              id="new-m2m-client-token-validity"
              type="number"
              label="Access token validity (minutes)"
              class="w-full input font-mono text-sm"
            />
            <p class="text-xs text-base-content/70 -mt-1 mb-2">
              Whole minutes, 5–60. Defaults to 15.
            </p>

            <div class="mt-3">
              <div class="text-sm font-medium mb-1">Client name preview</div>
              <div
                id="new-m2m-client-name-preview"
                class="rounded-box bg-base-200 p-2 font-mono text-sm"
              >
                <%= if @name_preview do %>
                  <span class="select-all">{@name_preview}</span>
                <% else %>
                  <span class="text-base-content/60">
                    Enter a ticket ID and purpose to preview the client name.
                  </span>
                <% end %>
              </div>
            </div>

            <p
              :if={@create_error}
              id="new-m2m-client-error"
              role="alert"
              class="text-error text-sm mt-2"
            >
              {@create_error}
            </p>

            <div class="modal-action">
              <.button id="new-m2m-client-cancel" type="button" phx-click="cancel_new_client">
                Cancel
              </.button>
              <.button
                id="new-m2m-client-submit"
                type="submit"
                variant="primary"
                disabled={not @create_form.source.valid?}
              >
                Create
              </.button>
            </div>
          </.form>
        </.modal>

        <%!--
        `M2M-A08`: shown exactly once. Only in the DOM while `@credentials`
        is set — see `CredentialsPanel`'s own moduledoc for why this is not
        `<.modal>`, and the moduledoc above for why opening the creation
        modal clears this assign (mutual exclusion, not incidental
        dismissal).
        --%>
        <CredentialsPanel.credentials_panel
          :if={@credentials}
          client_id={@credentials.client_id}
          client_secret={@credentials.client_secret}
          on_dismiss={JS.push("dismiss_credentials")}
        />
      </div>
    </Layouts.app>
    """
  end

  defp dom_id(%Client{client_id: client_id}), do: "m2m-client-" <> client_id

  defp date_unavailable_id(client_id), do: "m2m-client-date-unavailable-" <> client_id

  defp view_link_id(client_id), do: "view-client-" <> client_id

  # Fresh each time, never reused across an open/cancel cycle — an
  # unvalidated (`action: nil`) empty `%NewClient{}` so opening the form
  # shows no errors before the user has typed anything, matching
  # `NucleusWeb.SecretsLive`'s `build_create_form/1` precedent.
  defp build_create_form do
    %NewClient{}
    |> NewClient.changeset(%{})
    |> to_form(as: :new_client)
  end

  # `M2M-A07`: the exact name `Nucleus.M2M.ClientName.build/2` would produce
  # — never a template-side reconstruction of the naming convention. `nil`
  # when either field is blank (a half-built name like
  # `acme-control-plane--nightly-sync` teaches the wrong convention) or
  # either field has failed `Nucleus.M2M.NewClient.changeset/2`'s validation
  # (a preview of a name that cannot be created is worse than none).
  #
  # Computed here, in the event handler, into its own `:name_preview`
  # assign — never as a function call reading `@create_form` directly in
  # the template. `ClientName.build/2` reads `Nucleus.Scope.tenant_namespace/0`
  # at call time (not baked in), but LiveView's change tracking only
  # re-evaluates a template expression when the *assign* it closes over
  # changes; two `validate_new_client` events carrying identical
  # `ticket_id`/`purpose` produce a structurally identical changeset even
  # if `TENANT_NAMESPACE` changed between them, which would leave a
  # template-side call to this function rendering a stale name. Assigning
  # the computed string itself sidesteps that: the value assigned genuinely
  # differs when the tenant does, so the diff always carries it.
  defp preview_name(changeset) do
    ticket_id = Ecto.Changeset.get_field(changeset, :ticket_id)
    purpose = Ecto.Changeset.get_field(changeset, :purpose)

    cond do
      blank?(ticket_id) or blank?(purpose) -> nil
      Keyword.has_key?(changeset.errors, :ticket_id) -> nil
      Keyword.has_key?(changeset.errors, :purpose) -> nil
      true -> ClientName.build(ticket_id, purpose)
    end
  end

  defp blank?(nil), do: true
  defp blank?(value), do: String.trim(value) == ""
end
