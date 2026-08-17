defmodule NucleusWeb.SecretsLive do
  @moduledoc """
  The Secrets view for one environment — the gate every other Secrets action
  (`SEC-A01` onward) mounts through.

  Replaces the `SEC-S1`-marked placeholder wholesale (see ADR-0006 §"the
  disposable placeholder"), not incrementally.

  ## Validated in `handle_params/3`, not `mount/3`

  The environment name comes from the URL, and a `<.link patch={...}>` can
  change it without a remount — `handle_params/3` runs on every patch,
  `mount/3` does not. Putting the check in `mount/3` would let a user patch
  from a valid environment straight into an unvalidated one.

  ## One call to `Nucleus.Secrets.list/2`, not two

  `SEC-S1`'s original placeholder called `Nucleus.Environments.fetch/2`
  directly. `SEC-S2` collapsed that into a single call to
  `Nucleus.Secrets.list/2`, which gates through `Environments.fetch/2`
  internally — this module no longer calls it, and no longer keeps a
  `resolved_environment` assign (it was assigned by the placeholder and never
  read). `current_scope` is passed to the context wholesale, per Phoenix 1.8
  scope convention.

  ## Every outcome gets its own assign and DOM id

  `Nucleus.Secrets.list/2` can succeed, or fail with any
  `Nucleus.Backend.Error.kinds/0` value from either boundary it touches
  (`:tenant_api` via the environment gate, `:secrets` via the store) — this
  `case` must handle all of them without crashing:

  | Outcome | `:environment_status` | DOM id |
  |---|---|---|
  | `{:ok, refs}` | `:ok` | `#secrets-table` / `#secrets-empty` |
  | `kind: :invalid` | `:invalid` | `#secrets-invalid-environment` |
  | `kind: :not_found` | `:not_found` | `#secrets-environment-not-found` |
  | `kind: :unavailable, boundary: :tenant_api` | `:validation_unavailable` | `#secrets-validation-unavailable` |
  | `kind: :unavailable, boundary: :secrets` | `:secrets_unavailable` | `#secrets-unavailable` |
  | `kind: :auth_expired` (either boundary) | `:auth_expired` | `#secrets-auth-expired` |
  | anything else (`:already_exists`, `:not_configured`) | `:secrets_unavailable` | `#secrets-unavailable` |

  `:invalid` and `:not_found` only ever arrive with `boundary: :tenant_api` —
  the store is never reached once the gate rejects a name. The two
  `:unavailable` outcomes are otherwise identical (`kind: :unavailable`) and
  are told apart only by `boundary`, which is why this `case` matches on it
  explicitly rather than collapsing them — collapsing "not found" and
  "unavailable" would misinform the user about a real outage (`SEC-A17`), and
  the same reasoning applies to the store's own outage.

  `:auth_expired` is `SEC-S7`'s concern — this module renders a placeholder
  and does not implement retry semantics for it. Every other, unlisted kind
  (there are none today, but `kinds/0` could grow one) falls back to the same
  `:secrets_unavailable` rendering rather than crashing.

  Every branch keeps the shell intact (`<Layouts.app>`, `#tenant-identifier`)
  so the user can navigate away — a crashed LiveView is not an acceptable
  rendering of any of these. The raw environment name is never echoed
  unescaped — HEEx's default escaping is not defeated with `raw/1`.

  ## Values are never in reach, never mind on screen

  `Nucleus.Secrets.list/2` returns `%Nucleus.Secrets.SecretRef{}` structs,
  which have no `value` field — this module cannot render, prefetch, or leak
  a value during listing even by accident. The "Value" column renders a
  fixed-width mask that does not depend on the real value's length (which
  would leak it). Revealing a value is `SEC-S4`'s `handle_event("reveal", …)`
  — this module renders the control and a placeholder handler so a click
  cannot crash the LiveView before that ticket replaces it. Creating a
  secret is `SEC-S6`'s modal; the same placeholder-handler rule applies to
  the create button.

  ## Row DOM ids are a hash of the ARN, not the key (`SEC-S2` decision 2)

  The ARN is unique per secret and stable across renders (it encodes the
  path and key, not the value), so it survives the `stream_insert/3` that
  `SEC-S4`/`SEC-S5` perform when a row's reveal or edit state changes. An
  opaque id is worse to select against, so each row also carries
  `data-key={ref.key}` — later tickets should select on
  `[data-key="DATABASE_URL"]`, not on the row id, and must not recompute the
  hash in a test.

  `current_scope` and `environments` come from the `:authenticated`
  `live_session`'s `on_mount` hooks (`NucleusWeb.ScopeHook`,
  `NucleusWeb.EnvironmentsHook`) — this module does not assign either
  itself.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.Secrets
  alias Nucleus.Secrets.SecretRef

  @masked_value "••••••••"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:secrets, dom_id: &dom_id/1)
      |> stream(:secrets, [])

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"environment" => environment}, _uri, socket) do
    socket =
      socket
      |> assign(:environment, environment)
      |> fetch_secrets(environment)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("reveal", %{"key" => _key}, socket) do
    {:noreply, put_flash(socket, :info, "Revealing a secret's value is not yet implemented.")}
  end

  @impl Phoenix.LiveView
  def handle_event("create_secret", _params, socket) do
    {:noreply, put_flash(socket, :info, "Creating a secret is not yet implemented.")}
  end

  @impl Phoenix.LiveView
  def handle_event("retry", _params, socket) do
    {:noreply, fetch_secrets(socket, socket.assigns.environment)}
  end

  defp fetch_secrets(socket, environment) do
    case Secrets.list(environment, socket.assigns.current_scope) do
      {:ok, refs} ->
        socket
        |> assign(environment_status: :ok, secret_count: length(refs))
        |> stream(:secrets, refs, reset: true)

      {:error, %Error{kind: :invalid, boundary: :tenant_api}} ->
        assign(socket, environment_status: :invalid, secret_count: 0)

      {:error, %Error{kind: :not_found, boundary: :tenant_api}} ->
        assign(socket, environment_status: :not_found, secret_count: 0)

      {:error, %Error{kind: :unavailable, boundary: :tenant_api}} ->
        assign(socket, environment_status: :validation_unavailable, secret_count: 0)

      {:error, %Error{kind: :unavailable, boundary: :secrets}} ->
        assign(socket, environment_status: :secrets_unavailable, secret_count: 0)

      {:error, %Error{kind: :auth_expired}} ->
        assign(socket, environment_status: :auth_expired, secret_count: 0)

      {:error, %Error{}} ->
        assign(socket, environment_status: :secrets_unavailable, secret_count: 0)
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} environments={@environments}>
      <.empty_state
        :if={@environment_status == :invalid}
        id="secrets-invalid-environment"
        icon="hero-shield-exclamation"
        message="This is not a valid environment name."
      />
      <.empty_state
        :if={@environment_status == :not_found}
        id="secrets-environment-not-found"
        icon="hero-question-mark-circle"
        message={"No environment named \"#{@environment}\" was found for this tenant."}
      />
      <.empty_state
        :if={@environment_status == :validation_unavailable}
        id="secrets-validation-unavailable"
        icon="hero-exclamation-triangle"
        message="Can't verify this environment right now. Try again shortly."
      />
      <.empty_state
        :if={@environment_status == :secrets_unavailable}
        id="secrets-unavailable"
        icon="hero-exclamation-triangle"
        message="Can't reach the secrets store right now. Try again shortly."
      >
        <:action>
          <.button phx-click="retry">Retry</.button>
        </:action>
      </.empty_state>
      <.empty_state
        :if={@environment_status == :auth_expired}
        id="secrets-auth-expired"
        icon="hero-lock-closed"
        message="This environment's secrets can't be reached right now."
      />
      <div :if={@environment_status == :ok}>
        <div class="flex items-center justify-between gap-4 pb-4">
          <h1 class="text-lg font-semibold">Secrets</h1>
          <.button id="secrets-create-button" phx-click="create_secret">New secret</.button>
        </div>

        <.empty_state
          :if={@secret_count == 0}
          id="secrets-empty"
          icon="hero-inbox"
          message="No secrets found for this environment."
        />

        <div :if={@secret_count > 0} id="secrets-table">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Key</th>
                <th>Path</th>
                <th>ARN</th>
                <th>Last modified</th>
                <th>Value</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody id="secrets-table-body" phx-update="stream">
              <tr :for={{dom_id, ref} <- @streams.secrets} id={dom_id} data-key={ref.key}>
                <td>{ref.key}</td>
                <td>
                  <span class="block max-w-xs truncate" title={ref.path}>{ref.path}</span>
                </td>
                <td>
                  <span class="block max-w-xs truncate" title={ref.arn}>{ref.arn}</span>
                </td>
                <td>{format_last_modified(ref.last_modified)}</td>
                <td>
                  <span aria-hidden="true">{masked_value()}</span>
                  <span class="sr-only">value hidden</span>
                </td>
                <td>
                  <button
                    id={reveal_id(dom_id)}
                    type="button"
                    class="btn btn-sm"
                    phx-click="reveal"
                    phx-value-key={ref.key}
                  >
                    View
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp masked_value, do: @masked_value

  defp dom_id(%SecretRef{arn: arn}) do
    "secret-" <> (:crypto.hash(:sha256, arn) |> Base.url_encode64(padding: false))
  end

  defp reveal_id("secret-" <> hash), do: "reveal-" <> hash

  defp format_last_modified(nil), do: "—"

  defp format_last_modified(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end
end
