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
  would leak it), unless the row's key is in `:revealed` — see "Reveal, hide,
  and a failed reveal" below for that state. Creating a secret is `SEC-S6`'s
  modal; this module still only renders a placeholder handler for the create
  button so a click cannot crash the LiveView before that ticket replaces
  it.

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

  ## Copy affordances read from the full value, not the truncated span (`SEC-A02`)

  `<.copy_button>` (`SEC-S3`) is given `ref.path`/`ref.arn` directly — the
  same full strings the row's DOM id is hashed from — not the neighbouring
  `<span class="truncate">`'s text. Truncation there is CSS-only; the full
  value is always present in the DOM, and the button's `data-value` must
  carry it or a copy silently produces a broken, visually-truncated value.
  Button ids are suffixed with the row's `dom_id`, so they stay unique and
  stable across the same `stream_insert/3` churn the row id itself is
  designed to survive.

  ## Reveal, hide, and a failed reveal (`SEC-S4`)

  `:revealed` is a `%{key => Nucleus.Secrets.Secret.t()}` map — only the
  secrets a user has actually revealed are in it, and each entry carries its
  own fresh plaintext value. Nothing here caches a value across a
  hide/re-reveal cycle: `handle_event("reveal", ...)` always calls
  `Nucleus.Secrets.reveal/3` again, which is a fresh `Store.get_secret/2`
  call and a fresh `secret_viewed` audit record every time (`SEC-A03`).

  **Every reveal or hide re-streams the row** (`stream_insert/3`), converting
  the `Secret` back to a `SecretRef` first — `AGENTS.md` is explicit that an
  assign changing content *inside* a streamed item must re-stream that item,
  and this is the single most likely cause of a "reveal does nothing" bug.
  The stream itself still only ever carries `SecretRef` structs, which have
  no `value` field — the plaintext lives only in the `:revealed` assign, read
  directly from `@revealed` in the template, never smuggled into the stream.

  A failed reveal (`SEC-A05`) leaves `:revealed` untouched — the value stays
  masked, the control stays "View", and a kind-specific flash explains what
  happened. `:auth_expired` does not yet have `SEC-S7`'s shared handler to
  delegate to (that ticket is still open) — the copy here is deliberately
  generic and will move under that handler once it lands, not duplicate it.

  Hiding is local-only: it deletes the key from `:revealed` and re-streams
  the row, with no backend call and no audit event — the wiki's audit
  catalogue has no event for hiding a value.

  `:revealed` is reset to `%{}` on every `handle_params/3` call, so patching
  between environments (or navigating back to this same route) never carries
  a previously-revealed plaintext value across.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.Secrets
  alias Nucleus.Secrets.Secret
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
      |> assign(:revealed, %{})
      |> fetch_secrets(environment)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("reveal", %{"key" => key}, socket) do
    case Secrets.reveal(socket.assigns.environment, key, socket.assigns.current_scope) do
      {:ok, secret} ->
        socket =
          socket
          |> update(:revealed, &Map.put(&1, key, secret))
          |> stream_insert(:secrets, to_secret_ref(secret))

        {:noreply, socket}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, reveal_error_message(error))}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("hide", %{"key" => key}, socket) do
    {secret, revealed} = Map.pop(socket.assigns.revealed, key)

    socket =
      case secret do
        nil ->
          assign(socket, :revealed, revealed)

        %Secret{} = secret ->
          socket
          |> assign(:revealed, revealed)
          |> stream_insert(:secrets, to_secret_ref(secret))
      end

    {:noreply, socket}
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
                <% revealed = Map.get(@revealed, ref.key) %>
                <td>{ref.key}</td>
                <td>
                  <div class="flex items-center gap-1">
                    <span class="block max-w-xs truncate" title={ref.path}>{ref.path}</span>
                    <.copy_button id={"copy-path-#{dom_id}"} value={ref.path} label="Copy path" />
                  </div>
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <span class="block max-w-xs truncate" title={ref.arn}>{ref.arn}</span>
                    <.copy_button id={"copy-arn-#{dom_id}"} value={ref.arn} label="Copy ARN" />
                  </div>
                </td>
                <td>{format_last_modified(ref.last_modified)}</td>
                <td>
                  <div :if={revealed} class="flex items-center gap-2">
                    <span id={secret_value_id(dom_id)} class="font-mono text-sm break-all">
                      {revealed.value}
                    </span>
                    <.copy_button
                      id={copy_value_id(dom_id)}
                      value={revealed.value}
                      label="Copy value"
                    />
                  </div>
                  <div :if={!revealed}>
                    <span aria-hidden="true">{masked_value()}</span>
                    <span class="sr-only">value hidden</span>
                  </div>
                </td>
                <td>
                  <button
                    id={reveal_id(dom_id)}
                    type="button"
                    class="btn btn-sm"
                    phx-click={if revealed, do: "hide", else: "reveal"}
                    phx-value-key={ref.key}
                  >
                    {if revealed, do: "Hide", else: "View"}
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

  defp dom_id(%SecretRef{arn: arn}), do: dom_id_from_arn(arn)
  defp dom_id(%Secret{arn: arn}), do: dom_id_from_arn(arn)

  defp dom_id_from_arn(arn) do
    "secret-" <> (:crypto.hash(:sha256, arn) |> Base.url_encode64(padding: false))
  end

  defp reveal_id("secret-" <> hash), do: "reveal-" <> hash
  defp secret_value_id("secret-" <> hash), do: "secret-value-" <> hash
  defp copy_value_id("secret-" <> hash), do: "copy-value-" <> hash

  # The stream only ever carries `SecretRef` structs — no `value` field — so
  # a reveal or hide converts the `Secret` back before re-streaming
  # (`stream_insert/3`). The plaintext itself lives only in the `:revealed`
  # assign, read directly in the template.
  defp to_secret_ref(%Secret{key: key, path: path, arn: arn, last_modified: last_modified}) do
    %SecretRef{key: key, path: path, arn: arn, last_modified: last_modified}
  end

  defp reveal_error_message(%Error{kind: :not_found}) do
    "This secret no longer exists. It may have been removed outside Nucleus."
  end

  defp reveal_error_message(%Error{kind: :auth_expired}) do
    "This environment's secrets can't be reached right now."
  end

  defp reveal_error_message(%Error{kind: :unavailable}) do
    "Can't retrieve this secret's value right now. Try again shortly."
  end

  defp reveal_error_message(%Error{kind: :invalid}) do
    "That secret key isn't valid."
  end

  defp reveal_error_message(%Error{}) do
    "Can't retrieve this secret's value right now. Try again shortly."
  end

  defp format_last_modified(nil), do: "—"

  defp format_last_modified(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end
end
