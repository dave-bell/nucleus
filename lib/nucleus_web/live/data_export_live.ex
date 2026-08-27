defmodule NucleusWeb.DataExportLive do
  @moduledoc """
  The Data Export configuration table: enablement gate (`DEX-A01`), every
  key/value listed unmasked (`DEX-A03`), the empty state (`DEX-A12`), every
  `Nucleus.Backend.Error.kinds/0` value rendered as a distinct, shell-intact
  state (`DEX-A13` and friends), and no mutating affordance of any kind
  (`DEX-A14`) — issue #73, DEX-S1.

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

  ## `DEX-A14` — no mutating affordance anywhere

  No create button, no per-row edit/delete control, no "Actions" column.
  This is enforced one layer below the UI already — `Nucleus.NomadVars.Store`
  defines no create/delete callback of any kind — but the negative test
  proves the template itself adds none either.

  `:modify_index` is carried in assigns because DEX-S2's edit flow needs the
  value the page was loaded with for CAS — this ticket's job is only to
  carry it forward, not to use it.

  `current_scope` and `environments`/`expanded_categories` come from the
  `:authenticated` `live_session`'s `on_mount` hooks (`NucleusWeb.ScopeHook`,
  `NucleusWeb.EnvironmentsHook`), same order as `NucleusWeb.ApplicationsLive`
  — this module does not assign any of them itself.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.NomadVars
  alias NucleusWeb.DataExportLive.States

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    result =
      if connected?(socket) do
        NomadVars.list(scope)
      else
        NomadVars.fetch(scope)
      end

    {:ok, assign_result(socket, result)}
  end

  @impl Phoenix.LiveView
  def handle_event("retry", _params, socket) do
    result = NomadVars.list(socket.assigns.current_scope)
    {:noreply, assign_result(socket, result)}
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
                <td id={"var-" <> key <> "-value"}>{value}</td>
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
end
