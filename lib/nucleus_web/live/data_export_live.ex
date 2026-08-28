defmodule NucleusWeb.DataExportLive do
  @moduledoc """
  The Data Export configuration table: enablement gate (`DEX-A01`), every
  key/value listed unmasked (`DEX-A03`), the empty state (`DEX-A12`), every
  `Nucleus.Backend.Error.kinds/0` value rendered as a distinct, shell-intact
  state (`DEX-A13` and friends), no create-or-delete affordance of any kind
  (`DEX-A14`) — issue #73, DEX-S1 — plus inline edit/save/cancel for every
  key except `env_names`, and a failed save that is never silent (`DEX-A04`,
  `DEX-A05`, `DEX-A06` — issue #74, DEX-S2).

  ## Single module — no Index/Show split

  Unlike `NucleusWeb.M2MClientsLive`, there is no per-item detail route to
  justify `phx.gen.live`'s Index/Show split (`docs/adr/0018`): Data Export is
  one screen, one table, no drill-down — the same reasoning
  `NucleusWeb.ApplicationsLive` gives (`docs/adr/0025`).
  `NucleusWeb.DataExportLive.States` is the only sibling module.

  ## One call to `Nucleus.NomadVars.fetch/1`/`list/1`

  That single call answers three questions at once: whether Data Export is
  enabled at all (`DEX-A01`), what its current configuration is (`DEX-A03`),
  and — via `Nucleus.Backend.Error.kind()` — why it could not be shown
  (`DEX-A13` and every other kind). `assign_result/2` collapses every
  outcome to one of five states via `NucleusWeb.DataExportLive.States`:

  | Outcome | `:status` | DOM id |
  |---|---|---|
  | `{:ok, var_set}` | `:ok` | `#data-export-table` / `#data-export-empty` |
  | `kind: :not_found` | `:not_enabled` | `#data-export-not-enabled` |
  | `kind: :not_configured` | `:misconfigured` | `#data-export-misconfigured` |
  | `kind: :auth_expired` | `:auth_expired` | `#data-export-auth-expired` |
  | anything else (`:already_exists`, `:conflict`, `:invalid` — none of
    which `list/1` has reason to return today) | `:unavailable` |
    `#data-export-unavailable` |

  Every branch keeps `<Layouts.app>` intact (`#tenant-identifier` present) so
  the user can navigate away — the same "rest of the shell remains usable"
  guarantee `APP-A07` established.

  ## No URL params to gate — `mount/3`, not `handle_params/3`

  `/data-export` carries no identifier, matching `NucleusWeb.ApplicationsLive`'s
  own reasoning: nothing a `<.link patch={...}>` could change without a
  remount, so the one fetch happens in `mount/3` directly.

  `mount/3` runs once for the disconnected (static) render and once more
  after the client connects over the LiveView socket. Resolving via
  `Nucleus.NomadVars.fetch/1` (no audit) on the disconnected pass keeps the
  static HTML real — an empty content area until the socket connects would
  be a regression from every sibling this ticket patterns itself on, none of
  which leave the static render blank. Resolving via `Nucleus.NomadVars.list/1`
  (`fetch/1` + `Audit.emit(:nomad_vars_listed, ...)`) only once
  `connected?(socket)` is true means the one-time audit side effect fires
  exactly once per human page open, never twice for the same open — the same
  split `NucleusWeb.M2MClientsLive.Show` draws between `M2M.fetch/2` and
  `M2M.view/2`.

  ## `Items` is a plain map, not a stream

  Unlike `M2M`/`Secrets`/`Applications`' lists of structs, `VariableSet.t()`'s
  `items` is a `%{String.t() => String.t()}` with no stable native order and
  no per-row lifecycle — nothing to `stream_insert/3` or `stream_delete/3`.
  Rendered via a sorted `for` over
  `Enum.sort_by(Map.to_list(items), fn {key, _} -> String.downcase(key) end)`,
  the same name-ascending case-insensitive tiebreak `Nucleus.M2M.list/1` and
  `Nucleus.Secrets.list/1` use, for the same JSON-decoded-map ordering
  reason.

  ## One shared "last modified", not one per row

  `VariableSet.t()` carries a single `modify_index`/`modified_at` for the
  *whole* path, not one per key (EN-12/#72's correction of the wiki's
  per-key shape, DEX-D1) — so it renders once, outside the row loop, at
  `#data-export-modified-at`, never `#var-{key}-modified`.

  ## Row keys are not hashed

  `{key}` in `#var-{key}-value` is the raw configuration key (`description`,
  `env_names`, ...), unlike Secrets' ARN-hashed row ids (`docs/adr/0010`). A
  Nomad Variables key is not sensitive and is already visible in the cell
  next to it, so hashing it would add no protection and only cost
  readability.

  This does carry a residual assumption worth stating rather than leaving
  implicit: Nomad's own `Items` map imposes no charset restriction on a key
  (only the *path* is restricted to `docs/adr/0027`'s RFC3986-safe set — a
  key can be any string up to the 64KiB total-size cap), so a key containing
  `/` would produce a technically-valid HTML `id` that is not a valid CSS
  selector — `has_element?/2`'s `LazyHTML` selector would raise, not merely
  fail to match. This module accepts that risk rather than sanitizing or
  hashing, the same "dependency on upstream filtering" `docs/adr/0025`
  recorded for `Job.name` (which has no validating allowlist either): every
  known key today (`description`, `env_names`, `destination_bucket`) is an
  identifier Nucleus's own ops team defines when provisioning the variable,
  not arbitrary tenant input, and `DEX-A14` guarantees no new key is ever
  created through this feature. A future key that violates this convention
  is an ops-process bug, not something this view can validate against.

  ## `DEX-A14` — no create-or-delete affordance anywhere

  No create button, no per-row delete control. This is enforced one layer
  below the UI already — `Nucleus.NomadVars.Store` defines no create/delete
  callback of any kind — but the negative test proves the template itself
  adds none either. DEX-S2 adds a per-row **edit** control (below) for every
  key except `env_names` — `DEX-A14` was never "no mutating affordance at
  all," only "no create or delete of *keys*"; editing an existing key's
  value is exactly what `DEX-A04`/`DEX-A05` require.

  `current_scope` and `environments`/`expanded_categories` come from the
  `:authenticated` `live_session`'s `on_mount` hooks (`NucleusWeb.ScopeHook`,
  `NucleusWeb.EnvironmentsHook`), same order as `NucleusWeb.ApplicationsLive`
  — this module does not assign any of them itself.

  ## Inline edit — `DEX-A04`/`DEX-A05`, one code path for `description` and every other non-`env_names` key

  `DEX-A03` states values are not masked ("this is configuration, not secret
  data"), so unlike `NucleusWeb.SecretsLive`'s reveal-then-edit modal, there
  is no reveal gate here: editing is a per-row inline form swap inside the
  same `#var-{key}-value` cell the value itself renders in. Only the form
  *mechanics* follow `SecretsLive`'s edit flow
  (`secrets_live.ex:158-203,347-411,496-511`) — not its modal choreography,
  since there is no modal to choreograph.

  Three assigns track the single row that may be open at once:
  `:editing_key` (the key currently being edited, or `nil`), `:edit_form`
  (a `to_form/2`-built form over `NucleusWeb.DataExportLive.EditForm`), and
  `:edit_error` (the kind-mapped copy for a failed save, or `nil`). At most
  one row is editable at a time — clicking "Edit" on a different row while
  another is open simply moves `:editing_key`, discarding whatever unsaved
  text was in the row that closes; there is no cross-row unsaved-changes
  guard, matching `SecretsLive`'s own single-`:editing` simplicity extended
  to a keyed row.

  `"edit"` (`phx-value-key`) is rejected outright for `env_names` — `DEX-A14`
  and DEX-S3/S4's own picker-based editing both depend on no inline form
  ever existing for that key here. `"save_edit"` re-checks the submitted
  `key` against `socket.assigns.editing_key` — pattern-matched, not merely
  compared — before ever calling `Nucleus.NomadVars.update/5`, the same
  discipline `SecretsLive.handle_event("save_edit", ...)` applies
  (`secrets_live.ex:378-398`) against a stale or tampered `phx-value-key`. A
  disabled/hidden button is convenience only; this check is the actual gate.

  On save success, `:editing_key`/`:edit_form`/`:edit_error` all clear,
  `@variables` and `@modify_index` are replaced with the returned
  `var_set`'s — carrying forward a stale index here would make every
  *subsequent* edit's check-and-set conflict spuriously, defeating the whole
  point of the CAS the caller is trusted to carry forward
  (`Nucleus.NomadVars.update/5`'s moduledoc) — and a flash confirms the key
  was updated. `#var-{key}-value` therefore shows the new value immediately,
  no page reload.

  On save failure (`DEX-A06`): the form stays open, rebuilt from the
  *submitted* params rather than the original value, so the user's typed
  text is never lost; `:edit_error` is set from `edit_error_message/1`,
  which gives `:conflict` its own copy — "reload to see the current value" —
  distinct from every other kind's generic retry copy, since the correct
  next action genuinely differs (retry the same value vs. reload to see
  what changed). Cancel (`"cancel_edit"`) clears the three edit assigns with
  no adapter call and no audit side effect, mirroring `SecretsLive`'s own
  `"cancel_edit"`.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.NomadVars
  alias Nucleus.NomadVars.Value
  alias NucleusWeb.DataExportLive.EditForm
  alias NucleusWeb.DataExportLive.States

  @env_names_key "env_names"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    result =
      if connected?(socket) do
        NomadVars.list(scope)
      else
        NomadVars.fetch(scope)
      end

    socket =
      socket
      |> assign(editing_key: nil, edit_form: nil, edit_error: nil)
      |> assign_result(result)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("retry", _params, socket) do
    result = NomadVars.list(socket.assigns.current_scope)

    socket =
      socket
      |> assign(editing_key: nil, edit_form: nil, edit_error: nil)
      |> assign_result(result)

    {:noreply, socket}
  end

  # `DEX-A14`/DEX-S3-S4: `env_names` never gets an inline form here, no
  # matter what a client sends — the picker (a future ticket) is its only
  # edit path.
  @impl Phoenix.LiveView
  def handle_event("edit", %{"key" => @env_names_key}, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("edit", %{"key" => key}, socket) do
    case Enum.find(socket.assigns.variables, fn {k, _value} -> k == key end) do
      {^key, value} ->
        socket =
          socket
          |> assign(:editing_key, key)
          |> assign(:edit_form, build_edit_form(value))
          |> assign(:edit_error, nil)

        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate_edit", %{"value" => params}, socket) do
    if socket.assigns.editing_key do
      changeset =
        %EditForm{}
        |> EditForm.changeset(params)
        |> Map.put(:action, :validate)

      socket =
        socket
        |> assign(:edit_form, to_form(changeset, as: :value))
        # A stale failure banner (e.g. `:conflict`'s "reload and retry" copy)
        # must not linger while the user is actively retyping — it describes
        # the last submit, not the text currently in the box.
        |> assign(:edit_error, nil)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Re-checked here, not only in "edit" — `:editing_key` could have been
  # cleared (a cancel, a switch to another row) between opening the form and
  # submitting it, and the submitted `key` is client-controlled.
  @impl Phoenix.LiveView
  def handle_event("save_edit", %{"key" => key, "value" => params}, socket) do
    case socket.assigns.editing_key do
      ^key ->
        changeset =
          %EditForm{}
          |> EditForm.changeset(params)
          |> Map.put(:action, :validate)

        if changeset.valid? do
          save_edit(socket, key, Ecto.Changeset.get_field(changeset, :value))
        else
          {:noreply, assign(socket, :edit_form, to_form(changeset, as: :value))}
        end

      _not_editing_this_row ->
        {:noreply, put_flash(socket, :error, "That row is no longer open for editing.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("cancel_edit", _params, socket) do
    # No adapter call, no audit event — cancelling discards the edit and the
    # original value remains (`DEX-A05`).
    socket =
      socket
      |> assign(:editing_key, nil)
      |> assign(:edit_form, nil)
      |> assign(:edit_error, nil)

    {:noreply, socket}
  end

  defp save_edit(socket, key, value) do
    items = Map.new(socket.assigns.variables)
    scope = socket.assigns.current_scope

    case NomadVars.update(key, value, items, socket.assigns.modify_index, scope) do
      {:ok, var_set} ->
        sorted =
          Enum.sort_by(Map.to_list(var_set.items), fn {k, _value} -> String.downcase(k) end)

        socket =
          socket
          |> assign(:variables, sorted)
          |> assign(:modify_index, var_set.modify_index)
          |> assign(:modified_at, var_set.modified_at)
          |> assign(:editing_key, nil)
          |> assign(:edit_form, nil)
          |> assign(:edit_error, nil)
          |> put_flash(:info, "#{key} was updated.")

        {:noreply, socket}

      {:error, %Error{} = error} ->
        # `DEX-A06`: the form stays open (`:editing_key` untouched), rebuilt
        # from the submitted value (not the original) so the user's typed
        # text survives, and the value is never presented as saved.
        changeset =
          %EditForm{}
          |> EditForm.changeset(%{"value" => value})
          |> Map.put(:action, :validate)

        socket =
          socket
          |> assign(:edit_form, to_form(changeset, as: :value))
          |> assign(:edit_error, edit_error_message(error))

        {:noreply, socket}
    end
  end

  defp assign_result(socket, {:ok, var_set}) do
    sorted =
      Enum.sort_by(Map.to_list(var_set.items), fn {key, _value} -> String.downcase(key) end)

    assign(socket,
      status: :ok,
      variables: sorted,
      variable_count: map_size(var_set.items),
      variable_path: var_set.path,
      modify_index: var_set.modify_index,
      modified_at: var_set.modified_at
    )
  end

  defp assign_result(socket, {:error, %Error{kind: :not_found}}) do
    assign(socket, status: :not_enabled, variables: [], variable_count: 0)
  end

  defp assign_result(socket, {:error, %Error{kind: :not_configured}}) do
    assign(socket, status: :misconfigured, variables: [], variable_count: 0)
  end

  defp assign_result(socket, {:error, %Error{kind: :auth_expired}}) do
    assign(socket, status: :auth_expired, variables: [], variable_count: 0)
  end

  defp assign_result(socket, {:error, %Error{}}) do
    assign(socket, status: :unavailable, variables: [], variable_count: 0)
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
      <States.not_enabled :if={@status == :not_enabled} />
      <States.misconfigured :if={@status == :misconfigured} />
      <States.unavailable :if={@status == :unavailable} />
      <States.auth_expired :if={@status == :auth_expired} />

      <div :if={@status == :ok}>
        <h1 class="text-lg font-semibold pb-4">Data Export</h1>

        <.empty_state
          :if={@variable_count == 0}
          id="data-export-empty"
          icon="hero-inbox"
          message="No variables configured."
        />

        <div :if={@variable_count > 0} id="data-export-table">
          <p class="text-sm text-base-content/70 pb-2">
            Last modified: <span id="data-export-modified-at">{modified_at_text(@modified_at)}</span>
          </p>
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Key</th>
                <th>Value</th>
              </tr>
            </thead>
            <tbody id="data-export-table-body">
              <tr :for={{key, value} <- @variables} id={"var-" <> key} data-var-key={key}>
                <td class="font-medium">{key}</td>
                <td id={"var-" <> key <> "-value"}>
                  <%= if @editing_key == key do %>
                    <.form
                      for={@edit_form}
                      id={"var-#{key}-edit-form"}
                      phx-change="validate_edit"
                      phx-submit="save_edit"
                    >
                      <input type="hidden" name="key" value={key} />
                      <.input
                        field={@edit_form[:value]}
                        id={"var-#{key}-value-input"}
                        type="textarea"
                        label="Value"
                        rows="3"
                        class="w-full textarea font-mono text-sm"
                      />
                      <div
                        id={"var-#{key}-edit-count"}
                        class="text-xs text-base-content/70 text-right mt-1"
                      >
                        {edit_value_length(@edit_form)}/{Value.max_length()} characters
                      </div>
                      <p
                        :if={@edit_error}
                        id={"var-#{key}-edit-error"}
                        role="alert"
                        class="text-error text-sm mt-2"
                      >
                        {@edit_error}
                      </p>
                      <div class="flex gap-2 mt-2">
                        <.button
                          id={"var-#{key}-cancel-edit"}
                          type="button"
                          phx-click="cancel_edit"
                        >
                          Cancel
                        </.button>
                        <.button
                          id={"var-#{key}-save-edit"}
                          type="submit"
                          variant="primary"
                          phx-disable-with="Saving..."
                        >
                          Save
                        </.button>
                      </div>
                    </.form>
                  <% else %>
                    <div class="flex items-center justify-between gap-2">
                      <span>{value}</span>
                      <button
                        :if={key != "env_names"}
                        id={"var-#{key}-edit"}
                        type="button"
                        class="btn btn-xs"
                        phx-click="edit"
                        phx-value-key={key}
                      >
                        Edit
                      </button>
                    </div>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp modified_at_text(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  defp modified_at_text(nil), do: "unavailable"

  defp build_edit_form(value) do
    %EditForm{}
    |> EditForm.changeset(%{"value" => value})
    |> to_form(as: :value)
  end

  defp edit_value_length(form) do
    form[:value].value
    |> to_string()
    |> String.length()
  end

  defp edit_error_message(%Error{kind: :conflict}) do
    "This value changed since you loaded it. Reload to see the current value, then try again."
  end

  defp edit_error_message(%Error{kind: :not_found}) do
    "This key no longer exists."
  end

  # Defensive: `save_edit`'s own changeset gate rejects an invalid value
  # before `Nucleus.NomadVars.update/5` is ever called, so this kind should
  # not normally reach here — it exists because `update/5` enforces the
  # same rule independently (a direct `phx-submit`/event dispatch bypassing
  # the client-side changeset must not bypass the server-side check too).
  defp edit_error_message(%Error{kind: :invalid}) do
    "That value isn't valid."
  end

  defp edit_error_message(%Error{}) do
    "Can't save this value right now. Try again shortly."
  end
end
