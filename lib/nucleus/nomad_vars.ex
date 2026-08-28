defmodule Nucleus.NomadVars do
  @moduledoc """
  Scope and audit over `Nucleus.NomadVars.Store` (EN-12/#72) — the same split
  `Nucleus.Secrets` performs over `Nucleus.Secrets.Store` and `Nucleus.M2M`
  performs over `Nucleus.M2M.Clients`. Backs Data Export configuration
  (`docs/requirements/Data-Export-Configuration.md`).

  ## `fetch/1` vs. `list/1` — the same split `Nucleus.M2M.fetch/2`/`view/2` draw

  `fetch/1` resolves the variable set with **no** audit side effect;
  `list/1` is `fetch/1` plus the `nomad_vars_listed` emission on success.
  `NucleusWeb.DataExportLive.mount/3` calls `fetch/1` on the disconnected
  (static) render and `list/1` only once `connected?(socket)` is true — the
  same reasoning `NucleusWeb.M2MClientsLive.Show` gives for its own
  `fetch/2`/`view/2` split: `mount/3` runs once disconnected and once more
  after the socket connects, and an audited call on both passes would
  record two listings for one human page open. Unlike `M2M`, there is only
  one non-audited *and* one audited call here — `fetch/1` has no other
  caller today, but exists as its own function (not inlined into `list/1`)
  so the disconnected render still shows real data instead of nothing, the
  same guarantee `M2M.fetch/2` gives `M2MClientsLive.Show`'s static render.

  ## `list/1` audits on success only

  Mirrors `Nucleus.M2M.view/2` (`lib/nucleus/m2m.ex:224-239`): on
  `{:ok, var_set}`, emits `nomad_vars_listed` (`user: Scope.audit_user(scope)`,
  `tenant: scope.tenant`, `details: %{path: var_set.path}`) and *then* returns
  `{:ok, var_set}`. On any error, the error is returned unchanged and nothing
  is emitted — a listing that did not happen must not be recorded as one that
  did (AUD-A07).

  ## `:not_found` is not translated here

  `Nucleus.NomadVars.Store.read/0`'s `{:error, %Error{kind: :not_found}}`
  means "Data Export is not enabled for this tenant" (`DEX-A01`), not "the
  configuration failed to load" — see `Nucleus.NomadVars.Store`'s own
  moduledoc and `docs/adr/0027-nomad-vars-adapter.md`, Decision 7. This
  module passes that (and every other `Nucleus.Backend.Error.kind()`)
  through unchanged; `NucleusWeb.DataExportLive` is what maps `:not_found`
  to its own not-enabled state. A reader used to every other boundary's
  `:not_found` meaning "no such resource" would otherwise assume this one
  means "the load failed" — it does not.

  ## `update/5`, not `update/4` — an implementation-time correction to DEX-S2's own plan

  The issue plan names this function `update/4` (`key, value,
  expected_modify_index, scope`) but its own prose requires "building the
  new `Items` map" from "the caller-supplied current items" without ever
  calling `Store.read/0`. `Store.write/2` (`Nucleus.NomadVars.Store`,
  DEX-S1/EN-12) replaces the *entire* `Items` map on the wire — there is no
  way to assemble that map from only a key, a value, and an index. `items`
  must be a parameter; the plan's own `@spec` simply omitted it. Caught
  while implementing DEX-S2, not on the issue thread — recorded here the
  same way `docs/adr/0027-nomad-vars-adapter.md` records its own
  implementation-time corrections, since the acceptance criteria names this
  function by its (incorrect) arity.

  `update/5` (`DEX-A04`/`DEX-A05`) takes the caller-supplied `items` (the
  LiveView's own `@variables`, reassembled into a map), replaces one key
  with `value`, and calls `Store.write/2` with the new map and
  `expected_modify_index` (the index the page was loaded — or last saved —
  with). It deliberately does **not** call `Store.read/0` first: a fresh
  read-then-write would only catch a change that happened *during* the save
  request, not one that happened while the user was looking at the form
  with the page open — the actual race `DEX-A06`/the wiki's concurrency row
  describes. The caller is responsible for carrying the freshest `items`
  and index it has (and for updating both from every successful `update/5`
  return value, so the *next* edit's check-and-set is meaningful).

  On success, emits `nomad_var_updated` (`details: %{path: var_set.path, key:
  key}` — no `value` field exists in this event's catalogue entry
  (`audit/event.ex`), so the value cannot be logged even by mistake). On
  `{:error, %Error{kind: :conflict}}` or any other error, the error is
  returned unchanged and nothing is emitted — `DEX-A06`'s failure branch.

  This is the same function DEX-S3/DEX-S4 use to write `env_names`, with the
  audit event swapped at the call site (`env_names_updated`) rather than
  inside `update/5` — this function stays name-agnostic about which key it
  is writing.

  ## `update/5` validates `value`'s shape itself, not only the LiveView's form

  `Nucleus.NomadVars.Value.validate/1` (`:empty | :too_long`) runs here
  before `Store.write/2` is ever called, wrapped into
  `Nucleus.Backend.Error{kind: :invalid}` the same way
  `Nucleus.M2M.create_client/2` wraps `Purpose.validate/1`'s own bare-reason
  atom (`lib/nucleus/m2m.ex:159,176-181`) — the division of labour
  `Value`'s own moduledoc assigns to "a future `Nucleus.NomadVars` module."
  Caught in review, not on the issue thread: an earlier pass left this
  function trusting `NucleusWeb.DataExportLive.EditForm`'s changeset as the
  only gate, the same mistake `Nucleus.Secrets.update/4`'s own `with` chain
  (`Key.validate/1`, `Value.validate/1`, *then* the store call) exists to
  prevent for its own boundary. A disabled submit button or a client-side
  changeset is convenience, never enforcement — a future caller other than
  this one LiveView (DEX-S3/S4, a script, a test) gets no defense-in-depth
  without this check living here.
  """

  alias Nucleus.Audit
  alias Nucleus.Backend.Error
  alias Nucleus.NomadVars.Store
  alias Nucleus.NomadVars.Value
  alias Nucleus.NomadVars.VariableSet
  alias Nucleus.Scope

  @boundary Store.boundary()

  @doc """
  Reads this tenant's Data Export variable set, with no audit side effect.

  `scope` is accepted for call-site symmetry with every other context
  function (and to leave room for a future tenant-scoped read), but is not
  read by this function — see `list/1` for the audited equivalent, and the
  module doc for why both exist.
  """
  @spec fetch(Scope.t()) :: {:ok, VariableSet.t()} | {:error, Error.t()}
  def fetch(%Scope{} = _scope) do
    Store.read()
  end

  @doc """
  `fetch/1` plus the `nomad_vars_listed` audit emission (`DEX-A03`).

  On success, emits `nomad_vars_listed` with `details: %{path: var_set.path}`
  before returning. On failure, returns the error unchanged and emits
  nothing — see the moduledoc for why `:not_found` in particular is not
  translated into a different shape here.
  """
  @spec list(Scope.t()) :: {:ok, VariableSet.t()} | {:error, Error.t()}
  def list(%Scope{} = scope) do
    case fetch(scope) do
      {:ok, %VariableSet{} = var_set} = ok ->
        :ok =
          Audit.emit(:nomad_vars_listed,
            user: Scope.audit_user(scope),
            tenant: scope.tenant,
            details: %{path: var_set.path}
          )

        ok

      {:error, %Error{}} = error ->
        error
    end
  end

  @doc """
  Replaces `key`'s value with `value` in the caller-supplied `items` map,
  writing the whole map back via `Store.write/2` under check-and-set against
  `expected_modify_index` (`DEX-A04`/`DEX-A05`).

  `items` is the caller's own current `Items` map (`NucleusWeb.DataExportLive`'s
  `@variables`, reassembled) — this function does not re-fetch it, and does
  not re-read `expected_modify_index` fresh from the store either. Both are
  exactly what the caller last loaded or last saved, by design — see the
  moduledoc's "`update/5`, not `update/4`" section for why a fresh
  read-then-write would defeat check-and-set's actual purpose here, and why
  this function's arity corrects the issue plan's own `@spec`.

  `value` is validated via `Value.validate/1` before `Store.write/2` is ever
  called — see the moduledoc's "`update/5` validates `value`'s shape itself"
  section. An invalid value returns `{:error, %Error{kind: :invalid}}`
  immediately, with no store call and no audit emission.

  On `{:ok, var_set}`, emits `nomad_var_updated` (`details: %{path:
  var_set.path, key: key}`) before returning. On
  `{:error, %Error{kind: :conflict}}` — the stale-index case `DEX-A06`
  describes — or any other error, returns it unchanged and emits nothing.
  """
  @spec update(
          key :: String.t(),
          value :: String.t(),
          items :: %{String.t() => String.t()},
          expected_modify_index :: non_neg_integer(),
          Scope.t()
        ) :: {:ok, VariableSet.t()} | {:error, Error.t()}
  def update(key, value, items, expected_modify_index, %Scope{} = scope)
      when is_binary(key) and is_binary(value) and is_map(items) do
    with :ok <- validate_value(key, value),
         {:ok, %VariableSet{} = var_set} <-
           Store.write(Map.put(items, key, value), expected_modify_index) do
      :ok =
        Audit.emit(:nomad_var_updated,
          user: Scope.audit_user(scope),
          tenant: scope.tenant,
          details: %{path: var_set.path, key: key}
        )

      {:ok, var_set}
    end
  end

  defp validate_value(key, value) do
    case Value.validate(value) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error, Error.new(:invalid, @boundary, "value is invalid", %{key: key, reason: reason})}
    end
  end
end
