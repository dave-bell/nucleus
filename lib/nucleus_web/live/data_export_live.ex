defmodule NucleusWeb.DataExportLive do
  @moduledoc """
  The Data Export configuration table: enablement gate (`DEX-A01`), every
  key/value listed unmasked (`DEX-A03`), the empty state (`DEX-A12`), every
  `Nucleus.Backend.Error.kinds/0` value rendered as a distinct, shell-intact
  state (`DEX-A13` and friends), no create-or-delete affordance of any kind
  (`DEX-A14`) — issue #73, DEX-S1 — plus inline edit/save/cancel for every
  key except `env_names`, and a failed save that is never silent (`DEX-A04`,
  `DEX-A05`, `DEX-A06` — issue #74, DEX-S2) — plus `env_names`'s own
  environment picker: open, pre-selected (`DEX-A07`), select/deselect with a
  live count (`DEX-A08`), and a filter narrowing both lists (`DEX-A09` —
  issue #75, DEX-S3).

  ## Single module — no Index/Show split

  Unlike `NucleusWeb.M2MClientsLive`, there is no per-item detail route to
  justify `phx.gen.live`'s Index/Show split (`docs/adr/0018`): Data Export is
  one screen, one table, no drill-down — the same reasoning
  `NucleusWeb.ApplicationsLive` gives (`docs/adr/0025`).
  `NucleusWeb.DataExportLive.States` and `NucleusWeb.DataExportLive.JobStates`
  are the two sibling modules — one per boundary (`:nomad_vars`,
  `:nomad_jobs`), not one shared module for both; see `JobStates`'
  moduledoc for why they are not merged.

  ## The deployment status panel (`DEX-A02`, issue #77, DEX-S5)

  A second, independent read alongside the configuration table above: this
  page also shows the Data Export Nomad job's current status, version,
  cron schedule, and image, formatted entirely through the shared
  `NucleusWeb.Nomad.JobFormat` (`APP-S2`/#59) — no formatting logic of its
  own, per that ticket's plan. Rendered as a single horizontal row
  (status, version, schedule, image) rather than `<.description_list>`'s
  stacked rows — four short values read better side by side than as a
  four-row vertical list, and there is no per-row affordance (an edit
  button, a badge needing its own line) the way the configuration table's
  rows have that would push toward a vertical layout. The row is `flex`,
  not an evenly-split grid — status/version/schedule stay
  content-sized (`shrink-0`) while image (the one field long enough to
  need it, e.g. a full registry path) takes the remaining width
  (`flex-1`) and truncates with a `title` tooltip rather than wrapping or
  forcing the other three columns wider than their content needs.

  `Nucleus.NomadJobs.list/1` returns every parent job in the namespace, not
  one job — `fetch_job_status/1` filters for the entry whose `name` matches
  `Nucleus.NomadVars.Path.job_name/0` (EN-12/#72's derived
  `{tenant_namespace}-data_export` name, never a hardcoded literal). A job
  absent from that list is a real deployment scenario (Data Export enabled
  via its Variables but the job not yet deployed, or vice versa), not the
  same condition as `Nucleus.NomadJobs.list/1` itself erroring — but this
  ticket represents both by folding "job absent" into the existing
  `Nucleus.Backend.Error.kind() :not_found` vocabulary (favouring
  consistency with every other boundary in this codebase over a bespoke
  `{:not_found}` tuple) rather than distinguishing the two in the UI: see
  `NucleusWeb.DataExportLive.JobStates` for why they render the same single
  state.

  This is a second network call beyond `NomadVars.list/1`/`fetch/1` above,
  and renders from its own `:job` assign — a `Phoenix.LiveView.AsyncResult`,
  deliberately not reusing `:status`/`:variables`. A `Nucleus.NomadJobs`
  outage must not blank the configuration table this module already renders
  successfully from `NomadVars`, and a `NomadVars` failure must not hide a
  successful job status read — so the panel (`#data-export-job-status`)
  renders at the top level, outside every `@status`-gated branch below, not
  nested inside the `@status == :ok` block.

  The page itself carries one `<h1>Data Export</h1>`, not one per section —
  `#data-export-job-status` ("Deployment") and
  `#data-export-configuration` ("Configuration", wrapping every `States.*`
  branch and the `@status == :ok` table/empty-state below) are its two
  sibling `<h2>` sections, not two competing top-level pages glued together.
  The former per-status `<h1>Data Export</h1>` this ticket's earlier
  revision nested inside the `@status == :ok` block only was a leftover
  from before this page had a second (deployment status) section — every
  other `@status` branch rendered with no page title at all, which this
  fixes.

  `Nucleus.NomadJobs.list/1` emits no audit event (its own moduledoc), so —
  unlike the `fetch/1`/`list/1` split above, which exists solely to avoid a
  double `nomad_vars_listed` audit across `mount/3`'s two passes — there is
  no *audit* reason to gate this call on `connected?(socket)` the way that
  split does. It is still loaded via `Phoenix.LiveView.assign_async/3`
  (`fetch_job_status/1`), the same mechanism `NucleusWeb.EnvironmentsHook`
  uses for the sidebar's Environments section: `assign_async/3` itself only
  spawns the fetch once the socket is connected, so the disconnected static
  render shows `:loading` and the connected pass is what actually calls
  `Nucleus.NomadJobs.list/1` — chaining this ~15s-budgeted call after
  `NomadVars.list/1`/`fetch/1` inside `mount/3` directly would otherwise
  block first paint (including the Configuration table below, which has
  nothing to do with this boundary) on `Nucleus.NomadJobs`' own latency.
  Unlike `NucleusWeb.ApplicationsLive`'s own unconditional, *synchronous*
  `fetch_jobs/1` call in `mount/3` — a known gap against that ticket's own
  moduledoc claim, not a pattern this module repeats.

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

  ## Edit is a modal — `DEX-A04`/`DEX-A05`, one code path for `description` and every other non-`env_names` key

  Originally shipped as a per-row inline form swap (`DEX-A03`: values are
  unmasked, so no reveal-gate forced a modal the way `NucleusWeb.SecretsLive`
  needed one). Changed to a modal for symmetry with `SecretsLive`'s edit
  experience — a deliberate UX-consistency choice, not a reveal-gate
  requirement; see `docs/adr/0029` for the full history of both decisions.
  The modal's *mechanics* follow `SecretsLive`'s edit flow
  (`secrets_live.ex:158-203,347-411,496-511,701-782`) closely: one
  conditionally-rendered `<.modal>` (`:if={@editing_key}`, never toggled via
  client-side `show_modal/2`), not a second modal stacked on anything —
  `DataExportLive` has no reveal modal to stack against, so ADR-0012's
  `focusStack` gotcha does not apply here regardless.

  Four assigns track the single row that may be open at once:
  `:editing_key` (the key currently being edited, or `nil` — this alone
  gates the modal's `:if`, the same role `:revealed` plays for
  `SecretsLive`), `:editing_value` (the value as it was when the modal
  opened, kept for the save button's dirty-check — never rewritten by a
  failed save, mirroring `SecretsLive`'s `@revealed.value`), `:edit_form`
  (a `to_form/2`-built form over `NucleusWeb.DataExportLive.EditForm`), and
  `:edit_error` (the kind-mapped copy for a failed save, or `nil`). At most
  one row is editable at a time — clicking "Edit" on a different row while
  another is open simply replaces `:editing_key`/`:editing_value`,
  discarding whatever unsaved text was in the row that closes; there is no
  cross-row unsaved-changes guard, matching `SecretsLive`'s own
  single-`:editing` simplicity extended to a keyed row.

  `"edit"` (`phx-value-key`) is rejected outright for `env_names` — `DEX-A14`
  and DEX-S3/S4's own picker-based editing both depend on no edit modal ever
  opening for that key here. `"save_edit"` re-checks the submitted `key`
  against `socket.assigns.editing_key` — pattern-matched, not merely
  compared — before ever calling `Nucleus.NomadVars.update/5`, the same
  discipline `SecretsLive.handle_event("save_edit", ...)` applies
  (`secrets_live.ex:378-398`) against a stale or tampered `phx-value-key`. A
  disabled/hidden button is convenience only; this check is the actual gate.

  On save success, all four edit assigns clear — which, because the modal
  is wrapped in `:if={@editing_key}`, removes the modal and the form from
  the DOM in the same assign that confirms success, the same one-step
  re-mask `SecretsLive` gets from clearing `:revealed`. `@variables` and
  `@modify_index` are replaced with the returned `var_set`'s — carrying
  forward a stale index here would make every *subsequent* edit's
  check-and-set conflict spuriously, defeating the whole point of the CAS
  the caller is trusted to carry forward (`Nucleus.NomadVars.update/5`'s
  moduledoc) — and a flash confirms the key was updated. `#var-{key}-value`
  therefore shows the new value immediately, no page reload.

  On save failure (`DEX-A06`): the modal stays open (`:editing_key`/
  `:editing_value` untouched), the form rebuilt from the *submitted* params
  rather than the original value, so the user's typed text is never lost;
  `:edit_error` is set from `edit_error_message/1`, which gives `:conflict`
  its own copy — "reload to see the current value" — distinct from every
  other kind's generic retry copy, since the correct next action genuinely
  differs (retry the same value vs. reload to see what changed). Cancel
  (`"cancel_edit"`, also wired to the modal's own dismiss via `on_cancel`)
  clears all four edit assigns — closing the modal entirely, since there is
  no "view" content left to fall back to inside it — with no adapter call
  and no audit side effect, mirroring `SecretsLive`'s own `"cancel_edit"`.

  Save starts disabled and enables only once the entered value differs from
  `@editing_value`, the same dirty-check `SecretsLive` applies
  (`secrets_live.ex:738,939-941`) — UI convenience only; the server-side
  re-check above is what actually gates the write.

  ## `env_names`'s picker — `DEX-A07`–`A09`, a second modal, no write path yet

  `env_names` gets its own trigger (`#var-env_names-edit`, `phx-click`
  `"open_env_picker"`) in place of the inline-edit button every other row
  gets — `handle_event("edit", %{"key" => "env_names"}, socket)` still
  rejects that key outright, so this is a genuinely separate path, not a
  variant of the same one. `:env_picker` (a
  `NucleusWeb.DataExportLive.EnvironmentPicker.t()` or `nil`) alone gates a
  second conditionally-rendered `<.modal id="env-picker-modal">`, mirroring
  the edit modal's own "never exists until open" shape.

  Opening calls `Nucleus.TenantApi.list_environments/1` directly — not
  `EnvironmentsHook`'s `@environments` assign, which collapses every load
  error to `[]` and would misreport a genuine outage as "this tenant has
  zero environments." `{:error, %Error{}}` degrades to a flash and no modal
  opens at all, for any kind — there is no kind-specific copy here the way
  `edit_error_message/1` gives failed *saves*, since nothing has been
  attempted yet to fail in a specific way. On success, pre-selection is
  parsed fresh from `env_names`'s *current* row value
  (`parse_env_names/1`, tolerant of blank/whitespace entries the way
  `Nucleus.M2M.DenyList.parse/1` tolerates its own comma-separated value,
  though without that module's `:unset`/`"none"`-sentinel semantics, which
  don't apply to a plain selection list) — every open re-derives from the
  table, never from a previous picker's leftover state, so reopening after
  a discarded toggle starts exactly where a fresh page load would.

  `"toggle_env"` and `"filter_envs"` only ever call
  `EnvironmentPicker.toggle/2` and `.filter/2` on the `:env_picker` assign
  itself, with no adapter call of their own — `env_names` is written only by
  `"save_env_picker"` (`DEX-A10`, DEX-S4, below), never as a side effect of
  toggling or filtering. This ticket (DEX-S3) built only the picker's
  read-and-interact surface; saving the selection as an explicit add/remove
  delta and the full cancel-discards-changes guarantee were split into
  DEX-S4, mirroring `M2M-S4`/`M2M-S5`'s own form-interaction vs.
  submission-consequence split.

  ## `env_names`'s save and cancel (`DEX-A10`/`DEX-A11`, DEX-S4)

  `"save_env_picker"` reads `EnvironmentPicker.selected_names/1` — the raw,
  unfiltered selection (`docs/adr/0030`; never `selected_count/1`, which
  intersects against the current filter and exists only for the "Active
  (N)" badge) — and calls `Nucleus.NomadVars.update_env_names/4` with the
  same reassembled `items` map `save_edit/3` builds for `update/5`. On
  success, `:env_picker` clears (removing the modal, same as the edit
  modal's own success path) and `@variables`/`@modify_index`/`@modified_at`
  are replaced from the returned `var_set`. On failure, the picker stays
  open with `:env_picker_error` set from `edit_error_message/1` — the exact
  copy `save_edit/3` uses, `:conflict` included — never closed: closing on a
  failed save would let the user believe the picker's last state was
  persisted, the same reasoning `DEX-A06` gives for the edit modal.

  `"cancel_env_picker"` (the explicit Cancel button, and — via the modal's
  own `on_cancel` — Escape/backdrop dismissal) discards `:env_picker` and
  `:env_picker_error` with no adapter call and no audit event. Nothing was
  ever written to `env_names` before this point, so "the original value
  remains in effect" (`DEX-A11`) is true by construction: there is no value
  to revert, only in-memory picker state to drop. Reopening afterward calls
  `"open_env_picker"` again, which re-derives pre-selection from `env_names`'
  current stored value (never from the discarded picker) — the same
  guarantee DEX-S3 established, now exercised end-to-end across a real
  cancel.

  ### Each list scrolls at a fixed height; the modal itself does not grow

  `#env-picker-available` and `#env-picker-selected` are each a fixed
  `h-44` (five `btn-sm` rows plus their `space-y-1` gaps) with
  `overflow-y-auto` — a *fixed*, not a *max*, height: a filter that narrows
  a list to one match still renders a `176px` box with mostly empty space
  below it, rather than shrinking to fit. A tenant with hundreds of
  environments and a tenant with three render the same modal size; only
  the *lists* — and, within them, only how much of each fixed-size box is
  actually filled — change. `max-height` alone was tried first and
  rejected: it bounds growth but not shrinkage, so `DEX-A09`'s own filter
  narrowing shrank the box (and the modal with it) the moment matches
  dropped below five. Both columns carry the same fixed height regardless
  of how many rows either actually holds, so the two columns never
  visually desync either.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.NomadJobs
  alias Nucleus.NomadJobs.Job
  alias Nucleus.NomadVars
  alias Nucleus.NomadVars.EnvNames
  alias Nucleus.NomadVars.Path
  alias Nucleus.NomadVars.Value
  alias Nucleus.TenantApi
  alias Nucleus.TenantApi.Environment
  alias NucleusWeb.DataExportLive.EditForm
  alias NucleusWeb.DataExportLive.EnvironmentPicker
  alias NucleusWeb.DataExportLive.JobStates
  alias NucleusWeb.DataExportLive.States
  alias NucleusWeb.Nomad.JobFormat

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
      |> assign(editing_key: nil, editing_value: nil, edit_form: nil, edit_error: nil)
      |> assign(env_picker: nil, env_picker_error: nil)
      |> assign_result(result)
      |> fetch_job_status()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("retry", _params, socket) do
    result = NomadVars.list(socket.assigns.current_scope)

    socket =
      socket
      |> assign(editing_key: nil, editing_value: nil, edit_form: nil, edit_error: nil)
      |> assign_result(result)

    {:noreply, socket}
  end

  # `DEX-A02`/DEX-S5: a distinct event from `"retry"` above — the two calls
  # (`NomadVars.list/1`, `NomadJobs.list/1`) are independent boundaries with
  # independent failure states, so a retry on one must not touch the other.
  # Calling `assign_async/3` again on the same key (`fetch_job_status/1`)
  # cancels nothing to cancel — the previous attempt already resolved to
  # `:failed` by the time this event can fire, the button only being
  # rendered in `JobStates.unavailable/1`'s branch — and re-runs the fetch.
  @impl Phoenix.LiveView
  def handle_event("retry_job_status", _params, socket) do
    {:noreply, fetch_job_status(socket)}
  end

  # `DEX-A14`/DEX-S3-S4: `env_names` never gets an edit modal here, no
  # matter what a client sends — the picker (below) is its only edit path.
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
          |> assign(:editing_value, value)
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
    # No adapter call, no audit event — cancelling discards the edit and
    # closes the modal entirely (`DEX-A05`); unlike `SecretsLive`, there is
    # no "view" content left to fall back to inside it.
    socket =
      socket
      |> assign(:editing_key, nil)
      |> assign(:editing_value, nil)
      |> assign(:edit_form, nil)
      |> assign(:edit_error, nil)

    {:noreply, socket}
  end

  # `DEX-A07`: sourced from `Nucleus.TenantApi.list_environments/1` directly,
  # never from `EnvironmentsHook`'s `@environments` — that assign collapses
  # every load error to `[]` (`environments_hook.ex:81-84`), which would
  # render a genuine outage as "this tenant has zero environments" instead
  # of surfacing the failure. Pre-selection is re-derived from `env_names`'s
  # *current* stored value every time this opens, never from a prior
  # picker's leftover state, so a reopen after a discarded toggle starts
  # from the same place a fresh page load would.
  @impl Phoenix.LiveView
  def handle_event("open_env_picker", _params, socket) do
    case TenantApi.list_environments(socket.assigns.current_scope.token) do
      {:ok, environments} ->
        selected = EnvNames.parse(current_value(socket, @env_names_key))
        picker = EnvironmentPicker.new(available_environments(environments), selected)
        {:noreply, assign(socket, :env_picker, picker)}

      {:error, %Error{}} ->
        {:noreply, put_flash(socket, :error, "Couldn't load environments right now.")}
    end
  end

  # `DEX-A08`. No adapter call — nothing is saved until DEX-S4's save event.
  @impl Phoenix.LiveView
  def handle_event("toggle_env", %{"short_name" => short_name}, socket) do
    case socket.assigns.env_picker do
      nil ->
        {:noreply, socket}

      picker ->
        {:noreply, assign(socket, :env_picker, EnvironmentPicker.toggle(picker, short_name))}
    end
  end

  # `DEX-A09`. No adapter call.
  @impl Phoenix.LiveView
  def handle_event("filter_envs", %{"query" => query}, socket) do
    case socket.assigns.env_picker do
      nil ->
        {:noreply, socket}

      picker ->
        {:noreply, assign(socket, :env_picker, EnvironmentPicker.filter(picker, query))}
    end
  end

  # `DEX-A10`: saves the selection as an explicit add/remove delta via
  # `Nucleus.NomadVars.update_env_names/4`, reusing the same reassembled
  # `items` map `save_edit/3` builds for `update/5`.
  @impl Phoenix.LiveView
  def handle_event("save_env_picker", _params, socket) do
    case socket.assigns.env_picker do
      nil ->
        {:noreply, socket}

      picker ->
        new_names = EnvironmentPicker.selected_names(picker)
        items = Map.new(socket.assigns.variables)
        scope = socket.assigns.current_scope

        case NomadVars.update_env_names(new_names, items, socket.assigns.modify_index, scope) do
          {:ok, var_set} ->
            sorted =
              Enum.sort_by(Map.to_list(var_set.items), fn {k, _value} -> String.downcase(k) end)

            socket =
              socket
              |> assign(:variables, sorted)
              |> assign(:modify_index, var_set.modify_index)
              |> assign(:modified_at, var_set.modified_at)
              |> assign(:env_picker, nil)
              |> assign(:env_picker_error, nil)
              |> put_flash(:info, "Environment selection updated.")

            {:noreply, socket}

          {:error, %Error{} = error} ->
            # `DEX-A06`'s in-place failure handling, mirrored here: the picker
            # stays open (`:env_picker` untouched) with the kind-mapped error
            # surfaced inside the modal — closing on a failed save would let
            # the user believe the picker's last state was persisted.
            {:noreply, assign(socket, :env_picker_error, edit_error_message(error))}
        end
    end
  end

  # Closes the picker via the Cancel button, or the modal's `on_cancel`
  # (Escape/backdrop) — both routes for `DEX-A11`. No adapter call, no audit
  # event: nothing was ever saved, so there is nothing to discard beyond
  # this in-memory assign — the underlying `env_names` value is untouched.
  @impl Phoenix.LiveView
  def handle_event("cancel_env_picker", _params, socket) do
    {:noreply, assign(socket, env_picker: nil, env_picker_error: nil)}
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
          |> assign(:editing_value, nil)
          |> assign(:edit_form, nil)
          |> assign(:edit_error, nil)
          |> put_flash(:info, "#{key} was updated.")

        {:noreply, socket}

      {:error, %Error{} = error} ->
        # `DEX-A06`: the modal stays open (`:editing_key`/`:editing_value`
        # untouched), the form rebuilt from the submitted value (not the
        # original) so the user's typed text survives, and the value is
        # never presented as saved.
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

  # `DEX-A02`/DEX-S5: independent of `assign_result/2` above — a
  # `Nucleus.NomadJobs` outage must not touch `:status`/`:variables`, and a
  # `Nucleus.NomadVars` outage must not touch `:job`. `assign_async/3` only
  # starts the fetch once `connected?(socket)` — see the moduledoc, "The
  # deployment status panel" — so the disconnected static render shows
  # `:loading`, never blocking first paint on this boundary's own ~15s
  # budget (`Nucleus.NomadJobs.list/1`'s moduledoc).
  #
  # `scope` is read out of `socket.assigns` here, before the closure below,
  # rather than inside it — the closure runs in a separate process
  # (`Phoenix.LiveView.assign_async/3`'s own warning), so it must not close
  # over `socket` itself.
  defp fetch_job_status(socket) do
    scope = socket.assigns.current_scope

    assign_async(socket, :job, fn ->
      case fetch_data_export_job(scope) do
        {:ok, job} -> {:ok, %{job: job}}
        {:error, %Error{}} = error -> error
      end
    end)
  end

  # Two independent failure modes collapse to the same `{:error, Error.t()}`
  # shape here: the job absent from `NomadJobs.list/1`'s result (folded into
  # the existing `:not_found` kind rather than a bespoke `{:not_found}`
  # tuple — favouring consistency with every other boundary's vocabulary),
  # and the list call itself erroring with any other kind. Both render the
  # same `NucleusWeb.DataExportLive.JobStates.unavailable/1` state; see that
  # module's moduledoc for why they are not distinguished further.
  @spec fetch_data_export_job(Nucleus.Scope.t()) :: {:ok, Job.t()} | {:error, Error.t()}
  defp fetch_data_export_job(scope) do
    case NomadJobs.list(scope) do
      {:ok, jobs} ->
        case Enum.find(jobs, &(&1.name == Path.job_name())) do
          %Job{} = job ->
            {:ok, job}

          nil ->
            {:error,
             Error.new(
               :not_found,
               NomadJobs.boundary(),
               "the data export job is not deployed in this namespace",
               %{job_name: Path.job_name()}
             )}
        end

      {:error, %Error{}} = error ->
        error
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      environments={@environments}
      expanded_categories={@expanded_categories}
      active_section={@active_section}
      user_menu_open?={@user_menu_open?}
    >
      <h1 class="text-lg font-semibold pb-4">Data Export</h1>

      <div id="data-export-job-status" class="pb-6">
        <h2 class="text-base font-semibold pb-2">Deployment</h2>

        <.async_result :let={job} assign={@job}>
          <:loading>
            <p id="data-export-job-loading" class="text-sm text-base-content/60">
              Loading deployment status…
            </p>
          </:loading>
          <:failed>
            <JobStates.unavailable />
          </:failed>
          <dl class="flex flex-col gap-4 sm:flex-row sm:gap-x-16">
            <div class="shrink-0">
              <dt class="text-sm font-medium text-base-content/60">Status</dt>
              <dd class="text-sm">{JobFormat.status_text(job)}</dd>
            </div>
            <div class="shrink-0">
              <dt class="text-sm font-medium text-base-content/60">Version</dt>
              <dd class="text-sm">{JobFormat.version_text(job)}</dd>
            </div>
            <div class="shrink-0">
              <dt class="text-sm font-medium text-base-content/60">Schedule</dt>
              <dd class="text-sm">{JobFormat.schedule_text(job)}</dd>
            </div>
            <div class="min-w-0 flex-1">
              <dt class="text-sm font-medium text-base-content/60">Image</dt>
              <dd class="text-sm truncate" title={JobFormat.image_text(job)}>
                {JobFormat.image_text(job)}
              </dd>
            </div>
          </dl>
        </.async_result>
      </div>

      <div id="data-export-configuration">
        <h2 class="text-base font-semibold pb-2">Configuration</h2>

        <States.not_enabled :if={@status == :not_enabled} />
        <States.misconfigured :if={@status == :misconfigured} />
        <States.unavailable :if={@status == :unavailable} />
        <States.auth_expired :if={@status == :auth_expired} />

        <div :if={@status == :ok}>
          <.empty_state
            :if={@variable_count == 0}
            id="data-export-empty"
            icon="hero-inbox"
            message="No variables configured."
          />

          <div :if={@variable_count > 0} id="data-export-table">
            <p class="text-sm text-base-content/70 pb-2">
              Last modified:
              <span id="data-export-modified-at">{modified_at_text(@modified_at)}</span>
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
                    <div class="flex items-center justify-between gap-2">
                      <span>{value}</span>
                      <button
                        :if={key != "env_names"}
                        id={"var-#{key}-edit"}
                        type="button"
                        class="btn btn-sm"
                        phx-click="edit"
                        phx-value-key={key}
                      >
                        Edit
                      </button>
                      <button
                        :if={key == "env_names"}
                        id={"var-#{key}-edit"}
                        type="button"
                        class="btn btn-sm"
                        phx-click="open_env_picker"
                      >
                        Edit
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>

      <%!--
      Only in the DOM while it is open — mirroring `SecretsLive`'s reveal
      modal shape (see the moduledoc, "Edit is a modal"), even though there
      is no plaintext to protect here: the modal itself never exists until
      `:editing_key` is set.
      --%>
      <.modal :if={@editing_key} id="data-export-edit-modal" show on_cancel={JS.push("cancel_edit")}>
        <:title>{@editing_key}</:title>
        <.form
          for={@edit_form}
          id="data-export-edit-form"
          phx-change="validate_edit"
          phx-submit="save_edit"
        >
          <input type="hidden" name="key" value={@editing_key} />
          <.input
            field={@edit_form[:value]}
            id="data-export-edit-value"
            type="textarea"
            label="Value"
            rows="6"
            class="w-full textarea font-mono text-sm"
          />
          <div id="data-export-edit-count" class="text-xs text-base-content/70 text-right mt-1">
            {edit_value_length(@edit_form)}/{Value.max_length()} characters
          </div>
          <p
            :if={@edit_error}
            id="data-export-edit-error"
            role="alert"
            class="text-error text-sm mt-2"
          >
            {@edit_error}
          </p>
          <div class="modal-action">
            <.button id="data-export-cancel-edit" type="button" phx-click="cancel_edit">
              Cancel
            </.button>
            <.button
              id="data-export-save-edit"
              type="submit"
              variant="primary"
              disabled={not edit_dirty?(@edit_form, @editing_value)}
              phx-disable-with="Saving..."
            >
              Save
            </.button>
          </div>
        </.form>
      </.modal>

      <%!--
      `DEX-A07`–`A09`. Only in the DOM while `:env_picker` is set — the same
      "never exists until open" shape as the edit modal above, and for the
      same reason: `EnvironmentPicker.new/2` re-derives pre-selection from
      `env_names`'s current stored value on every open, so there is no
      stale state to protect against by keeping the modal mounted-but-hidden
      between opens.
      --%>
      <.modal
        :if={@env_picker}
        id="env-picker-modal"
        show
        on_cancel={JS.push("cancel_env_picker")}
      >
        <:title>Environments for Data Export</:title>

        <.form
          for={to_form(%{"query" => @env_picker.filter}, as: :env_filter)}
          id="env-picker-filter-form"
          phx-change="filter_envs"
          phx-submit="filter_envs"
        >
          <.input
            type="search"
            id="env-picker-filter"
            name="query"
            value={@env_picker.filter}
            placeholder="Filter environments..."
            phx-debounce="200"
          />
        </.form>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <h3 class="font-semibold text-sm mb-2">Available</h3>
            <ul
              id="env-picker-available"
              class="space-y-1 h-44 overflow-y-auto rounded-md border border-base-300 p-2"
            >
              <li
                :for={env <- EnvironmentPicker.available_matches(@env_picker)}
                id={"env-picker-available-#{env.short_name}"}
              >
                <button
                  type="button"
                  class="btn btn-sm btn-block justify-start"
                  phx-click="toggle_env"
                  phx-value-short_name={env.short_name}
                >
                  {env.label || env.short_name}
                </button>
              </li>
            </ul>
          </div>

          <div>
            <h3 class="font-semibold text-sm mb-2">
              Active
              <span id="env-picker-selected-count" class="font-normal text-base-content/70">
                ({EnvironmentPicker.selected_count(@env_picker)})
              </span>
            </h3>
            <ul
              id="env-picker-selected"
              class="space-y-1 h-44 overflow-y-auto rounded-md border border-base-300 p-2"
            >
              <li
                :for={env <- EnvironmentPicker.selected_matches(@env_picker)}
                id={"env-picker-selected-#{env.short_name}"}
              >
                <button
                  type="button"
                  class="btn btn-sm btn-block btn-primary justify-start"
                  phx-click="toggle_env"
                  phx-value-short_name={env.short_name}
                >
                  {env.label || env.short_name}
                </button>
              </li>
            </ul>
          </div>
        </div>

        <p
          :if={@env_picker_error}
          id="env-picker-error"
          role="alert"
          class="text-error text-sm mt-4"
        >
          {@env_picker_error}
        </p>

        <div class="modal-action">
          <.button id="env-picker-cancel" type="button" phx-click="cancel_env_picker">
            Cancel
          </.button>
          <.button
            id="env-picker-save"
            type="button"
            variant="primary"
            phx-click="save_env_picker"
            phx-disable-with="Saving..."
          >
            Save
          </.button>
        </div>
      </.modal>
    </Layouts.app>
    """
  end

  defp modified_at_text(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  defp modified_at_text(nil), do: "unavailable"

  # `env_names`'s current stored value — `@variables` is a sorted list of
  # `{key, value}` tuples (`docs/adr/0028`), not a map, so this mirrors the
  # `"edit"` handler's own `Enum.find/2` rather than map access syntax.
  defp current_value(socket, key) do
    case Enum.find(socket.assigns.variables, fn {k, _value} -> k == key end) do
      {^key, value} -> value
      nil -> nil
    end
  end

  # `DEX-A07`: the tenant's non-archived environments, name-sorted
  # case-insensitively — the same display-name fallback (`label || short_name`)
  # `NucleusWeb.EnvironmentsLive` already uses, and the same convention
  # DEX-S1's row ordering established for this LiveView. Deliberately not
  # `NucleusWeb.SidebarEnvironments.group/1` — that module also groups by
  # category, which a flat picker does not want, and its own moduledoc
  # scopes archived-exclusion to the sidebar specifically.
  @spec available_environments([Environment.t()]) :: [Environment.t()]
  defp available_environments(environments) do
    environments
    |> Enum.reject(& &1.archived?)
    |> Enum.sort_by(&String.downcase(&1.label || &1.short_name))
  end

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

  defp edit_dirty?(form, original_value) do
    to_string(form[:value].value) != to_string(original_value)
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
