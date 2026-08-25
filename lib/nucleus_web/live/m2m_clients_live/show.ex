defmodule NucleusWeb.M2MClientsLive.Show do
  @moduledoc """
  A client's detail view (`M2M-A03`), token validity display (`M2M-A16`),
  and the deliberate absence of any rename/reconfigure/delete affordance
  (`M2M-A15`) — M2M-S3, issue #36. Replaces M2M-S2 / #35's stub body without
  touching the router or `NucleusWeb.M2MClientsLive.Index` (Decision 7).

  ## `mount/3`, not `handle_params/3` — Decision 7, `docs/adr/0018`

  This route is reached only by a `navigate` from `Index` (`/m2m/clients` ->
  `/m2m/clients/:client_id`), never by a `patch` between two client IDs — a
  fresh remount happens on every navigation, so there is nothing to
  re-validate on a patch that never occurs. `Nucleus.M2M.fetch/2` (via
  `view/2`, see below) is called from `mount/3` directly, matching
  `phx.gen.live`'s own `Show.mount/3` shape and `Index`'s identical
  reasoning for having no `handle_params/3` of its own.

  ## `m2m_client_viewed` fires exactly once per open, not per render

  `mount/3` runs once for the disconnected (static) render and once more
  after the client connects over the LiveView socket — both with the same
  `client_id`. Resolving via plain `Nucleus.M2M.fetch/2` (no audit) on the
  disconnected pass keeps the static HTML correct; resolving via
  `Nucleus.M2M.view/2` (`fetch/2` + `Audit.emit(:m2m_client_viewed, ...)`)
  only once `connected?(socket)` is true means the one-time audit side
  effect fires exactly once per human page open, never twice for the same
  open and never on a failed lookup — `view/2` only emits on success.

  ## Every `Nucleus.Backend.Error.kinds/0` value gets its own state

  | Outcome | `:status` | DOM id |
  |---|---|---|
  | `{:ok, detail}` | `:ok` | `#m2m-client-detail` |
  | `kind: :invalid` (`M2M-A13`) | `:invalid` | `#m2m-client-invalid-id` |
  | `kind: :not_found` (`M2M-A14`) | `:not_found` | `#m2m-client-not-found` |
  | `kind: :not_configured` | `:misconfigured` | `#m2m-clients-misconfigured` |
  | `kind: :unavailable` (and `:already_exists`, which `fetch/2` has no
    reason to return) | `:unavailable` | `#m2m-clients-unavailable` |
  | `kind: :auth_expired` | `:auth_expired` | `#m2m-clients-auth-expired` |

  The three collapsed error states reuse
  `NucleusWeb.M2MClientsLive.States` — the same real component `Index`
  uses, not a copy-paste starting point (Decision 7) — and add this
  module's own `:invalid`/`:not_found` markup, since those two kinds are
  specific to resolving a single client by ID and have no equivalent in
  `Index`'s list-level `case`.

  Every branch keeps the shell intact (`<Layouts.app>`, `#tenant-identifier`)
  so the operator can navigate away; a crashed LiveView is not an acceptable
  rendering of any of them. **No client detail renders in any error
  state** — no ID, no name, no scope, no validity, no created date, and no
  rotation control.

  ## `M2M-A15` — no rename, reconfigure, or delete affordance

  The only mutating affordance this feature offers at all is secret
  rotation (`M2M-A11`, `#rotate-secret-button` below) — no rename,
  reconfigure, or delete control exists anywhere in this module, and none
  is planned.

  ## Secret rotation (`M2M-A11`, `M2M-A12`) — M2M-S6, #39

  `#rotate-secret-button` opens `#rotate-secret-confirm` (`<.modal>`,
  `on_cancel` -> `"cancel_rotate"`), stating the three facts `M2M-A12`
  requires before anything happens. Confirming calls `Nucleus.M2M.rotate/2`
  — which resolves through the same `fetch/2` gate as this module's own
  `mount/3`, so a deny-listed or out-of-tenant client cannot be rotated
  either — and on success renders `NucleusWeb.M2MClientsLive.CredentialsPanel`
  verbatim (`M2M-S5`, #38), parameterised with `title="Secret rotated"`
  rather than forked. Cancelling, the backdrop, and Escape all reach
  `"cancel_rotate"`, which makes **no** call to `rotate/2` and assigns
  nothing else — no backend call, no audit event, matching `M2M-A12`'s
  "the user can cancel without making any change."

  ### Mutual exclusion — the same hazard `docs/adr/0020` records for `Index`

  `:confirming_rotate` and `:credentials` both push onto the module-global
  `focusStack` (`<.modal>` via `JS.push_focus/1`/`JS.pop_focus/1`;
  `CredentialsPanel` the same pair directly) — having both mounted at once
  would double-pop it on whichever closes second. `"rotate"`'s success
  branch clears `:confirming_rotate` in the same assign that sets
  `:credentials`; every other branch of `"rotate"` clears both, so the two
  are never simultaneously true.

  ### Failure — a failed rotation collapses to the same five states `mount/3` does, minus `:unavailable`

  `:not_found`, `:invalid`, `:not_configured`, and `:auth_expired` replace
  `:status` exactly as `assign_result/2` already does for `mount/3` — the
  client detail (and the rotation control with it) stops rendering,
  because none of those four means "try again," they mean the page's own
  premise (a resolvable, in-tenant client) no longer holds.

  `:unavailable` is different: Cognito's rotation sequence is list, delete
  the older secret, add a new one, and a failure can land after the delete
  and before the add — the client may now have only one secret. Collapsing
  this to the page-level `:unavailable` state would hide that detail
  *and* the client behind a generic retry screen that implies nothing
  changed. Instead `:rotate_error` carries copy that says exactly the
  opposite — reload and check, don't assume — while `#m2m-client-detail`
  keeps rendering and the rotate button stays available, so "the operator
  can retry" means the same confirm-and-rotate flow, not a second control.

  ## The client ID is never echoed via `raw/1`

  HEEx escapes interpolated content by default; `{@detail.client_id}` and
  every other field render through ordinary interpolation, never `raw/1` —
  there is no reason to defeat HEEx's own escaping here.

  `current_scope` and `environments` come from the `:authenticated`
  `live_session`'s `on_mount` hooks, same as `Index` and
  `NucleusWeb.SecretsLive` — this module does not assign either itself.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.M2M
  alias Nucleus.M2M.ClientCredentials
  alias Nucleus.M2M.ClientDetail
  alias Nucleus.M2M.TokenValidity
  alias NucleusWeb.M2MClientsLive.CredentialsPanel
  alias NucleusWeb.M2MClientsLive.Format
  alias NucleusWeb.M2MClientsLive.States

  @impl Phoenix.LiveView
  def mount(%{"client_id" => client_id}, _session, socket) do
    scope = socket.assigns.current_scope

    result =
      if connected?(socket) do
        M2M.view(client_id, scope)
      else
        M2M.fetch(client_id, scope)
      end

    socket =
      socket
      |> assign(:client_id, client_id)
      |> assign(:confirming_rotate, false)
      |> assign(:credentials, nil)
      |> assign(:rotate_error, nil)
      |> assign_result(result)

    {:ok, socket}
  end

  defp assign_result(socket, {:ok, %ClientDetail{} = detail}) do
    assign(socket, status: :ok, detail: detail)
  end

  defp assign_result(socket, {:error, %Error{kind: :invalid}}) do
    assign(socket, status: :invalid, detail: nil)
  end

  defp assign_result(socket, {:error, %Error{kind: :not_found}}) do
    assign(socket, status: :not_found, detail: nil)
  end

  defp assign_result(socket, {:error, %Error{kind: :not_configured}}) do
    assign(socket, status: :misconfigured, detail: nil)
  end

  defp assign_result(socket, {:error, %Error{kind: :auth_expired}}) do
    assign(socket, status: :auth_expired, detail: nil)
  end

  defp assign_result(socket, {:error, %Error{}}) do
    assign(socket, status: :unavailable, detail: nil)
  end

  # Opens `#rotate-secret-confirm` — no backend call yet, matching
  # `M2M-A12`'s "the prompt explains..." (the explaining happens before any
  # action is taken, not after).
  @impl Phoenix.LiveView
  def handle_event("confirm_rotate", _params, socket) do
    {:noreply, assign(socket, confirming_rotate: true, rotate_error: nil)}
  end

  # Every dismissal route `#rotate-secret-confirm` offers — the Cancel
  # button, Escape, and the backdrop — arrives here, carrying no params.
  # `M2M-A12`'s "the user can cancel without making any change": this
  # clause makes no call to `Nucleus.M2M.rotate/2`, so it performs no
  # backend rotation and emits no audit event, by construction — there is
  # no code path from here to either.
  @impl Phoenix.LiveView
  def handle_event("cancel_rotate", _params, socket) do
    {:noreply, assign(socket, confirming_rotate: false)}
  end

  # `M2M-A11` — the only path that actually rotates anything, reached only
  # after `"confirm_rotate"` has rendered the modal and the operator has
  # clicked its submit button.
  @impl Phoenix.LiveView
  def handle_event("rotate", _params, socket) do
    scope = socket.assigns.current_scope
    result = M2M.rotate(socket.assigns.client_id, scope)

    {:noreply, assign_rotate_result(socket, result)}
  end

  # The credentials panel's own, sole dismissal route — see
  # `CredentialsPanel`'s moduledoc for why it has no other. Once this runs,
  # the secret is gone from both the rendered HTML and this socket's
  # assigns.
  @impl Phoenix.LiveView
  def handle_event("dismiss_credentials", _params, socket) do
    {:noreply, assign(socket, :credentials, nil)}
  end

  # Success: the modal closes, the one-time panel opens with the new
  # secret — `:confirming_rotate` and `:credentials` are set in the same
  # step so the two are never both true (see the moduledoc's "Mutual
  # exclusion" section).
  defp assign_rotate_result(socket, {:ok, %ClientCredentials{} = credentials}) do
    assign(socket, confirming_rotate: false, credentials: credentials, rotate_error: nil)
  end

  # The client is gone, or was never visible to this tenant — same
  # collapse `assign_result/2` already gives `mount/3` for `:not_found`.
  defp assign_rotate_result(socket, {:error, %Error{kind: :not_found}} = result) do
    assign_result(assign(socket, confirming_rotate: false), result)
  end

  defp assign_rotate_result(socket, {:error, %Error{kind: :invalid}} = result) do
    assign_result(assign(socket, confirming_rotate: false), result)
  end

  defp assign_rotate_result(socket, {:error, %Error{kind: :not_configured}} = result) do
    assign_result(assign(socket, confirming_rotate: false), result)
  end

  defp assign_rotate_result(socket, {:error, %Error{kind: :auth_expired}} = result) do
    assign_result(assign(socket, confirming_rotate: false), result)
  end

  # `:unavailable` (and any other kind `Nucleus.M2M.Clients.rotate_secret/1`
  # could in principle surface): the client keeps rendering — the failure
  # is Cognito's, not proof the client stopped existing — but the copy is
  # deliberately not "nothing happened." Cognito's rotation sequence is
  # list, delete the older secret, add a new one; a failure can land after
  # the delete and before the add, so the client may now hold only one
  # secret. Telling the operator to reload and check, rather than implying
  # a safe no-op, is the ticket's own instruction.
  defp assign_rotate_result(socket, {:error, %Error{}}) do
    assign(socket,
      confirming_rotate: false,
      rotate_error:
        "Rotating the secret failed. Reload this page and check before retrying — " <>
          "the previous secret may or may not still be valid."
    )
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      environments={@environments}
      expanded_categories={@expanded_categories}
    >
      <States.misconfigured :if={@status == :misconfigured} />
      <States.unavailable :if={@status == :unavailable} />
      <States.auth_expired :if={@status == :auth_expired} />

      <.empty_state
        :if={@status == :invalid}
        id="m2m-client-invalid-id"
        icon="hero-exclamation-triangle"
        message="That's not a valid M2M client ID."
      />

      <.empty_state
        :if={@status == :not_found}
        id="m2m-client-not-found"
        icon="hero-magnifying-glass"
        message="No such M2M client."
      />

      <div :if={@status == :ok} id="m2m-client-detail">
        <div class="flex items-center justify-between gap-4 pb-4">
          <h1 class="text-lg font-semibold">{@detail.client_name}</h1>
          <.link navigate={~p"/m2m/clients"} class="btn btn-sm btn-ghost">
            Back to clients
          </.link>
        </div>

        <dl class="grid grid-cols-1 gap-4">
          <div>
            <dt class="text-sm text-base-content/60">Client ID</dt>
            <dd id="m2m-client-id" class="font-mono text-sm">{@detail.client_id}</dd>
          </div>

          <div>
            <dt class="text-sm text-base-content/60">Client name</dt>
            <dd id="m2m-client-name">{@detail.client_name}</dd>
          </div>

          <div>
            <dt class="text-sm text-base-content/60">OAuth scope</dt>
            <dd id="m2m-client-scope" class="font-mono text-sm">{@detail.scope}</dd>
          </div>

          <div>
            <dt class="text-sm text-base-content/60">Access token validity</dt>
            <dd id="m2m-client-token-validity">
              {TokenValidity.humanize(@detail.token_validity_seconds)}
            </dd>
          </div>

          <div>
            <dt class="text-sm text-base-content/60">Created</dt>
            <dd id="m2m-client-created">{Format.created_date(@detail.created_date)}</dd>
          </div>
        </dl>

        <p id="m2m-client-secret-note" class="mt-6 text-sm text-base-content/70">
          The client secret is shown only once, at creation or rotation, and cannot be
          retrieved again afterward. If it's been lost, rotating the secret is the only
          recovery.
        </p>

        <div
          :if={@rotate_error}
          id="rotate-secret-error"
          role="alert"
          class="alert alert-error mt-4 items-start"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 mt-0.5" />
          <span>{@rotate_error}</span>
        </div>

        <div class="mt-6">
          <.button
            id="rotate-secret-button"
            type="button"
            class="btn btn-warning btn-soft"
            phx-click="confirm_rotate"
          >
            Rotate secret
          </.button>
        </div>
      </div>

      <%!--
      `M2M-A12`: shown before anything happens, states all three facts, and
      every dismissal route (Cancel, Escape, backdrop) reaches
      `"cancel_rotate"`, which rotates nothing — see the moduledoc's
      "Secret rotation" section.
      --%>
      <.modal
        :if={@confirming_rotate}
        id="rotate-secret-confirm"
        show
        on_cancel={JS.push("cancel_rotate")}
      >
        <:title>Rotate secret for {@detail.client_name}?</:title>
        <p class="mb-2">A new secret will be generated for this client.</p>
        <p class="mb-2">
          The old secret remains valid until the next rotation, so integrations can be
          updated without downtime — there is no need to update them immediately.
          Rotating again before every integration has moved to the new secret will
          invalidate the secret those integrations are still using.
        </p>
        <p class="mb-4">The client ID will not change.</p>

        <div class="modal-action">
          <.button id="rotate-secret-cancel" type="button" phx-click="cancel_rotate">
            Cancel
          </.button>
          <.button
            id="rotate-secret-confirm-submit"
            type="button"
            class="btn btn-warning"
            phx-click="rotate"
          >
            Rotate secret
          </.button>
        </div>
      </.modal>

      <%!--
      `M2M-A11`: shown exactly once, reusing `M2M-S5` / #38's panel
      verbatim — same DOM ids, same warning, same dismiss-only behaviour —
      parameterised only with `title`, per that component's own doc. Only
      in the DOM while `@credentials` is set, mutually exclusive with the
      confirmation modal above (see the moduledoc).
      --%>
      <CredentialsPanel.credentials_panel
        :if={@credentials}
        title="Secret rotated"
        client_id={@credentials.client_id}
        client_secret={@credentials.client_secret}
        on_dismiss={JS.push("dismiss_credentials")}
      />
    </Layouts.app>
    """
  end
end
