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
  rotation (`M2M-A11`), and that control belongs to M2M-S6 (#39), not this
  ticket — `#m2m-client-detail` renders nothing in its place today, on
  purpose, so a negative test for "no rename/edit/delete control" stays
  unambiguous rather than needing to also distinguish a disabled
  placeholder from a real one.

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
  alias Nucleus.M2M.ClientDetail
  alias Nucleus.M2M.TokenValidity
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

    {:ok, assign_result(socket, result)}
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

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} environments={@environments}>
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
      </div>
    </Layouts.app>
    """
  end
end
