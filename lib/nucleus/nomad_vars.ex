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
  """

  alias Nucleus.Audit
  alias Nucleus.Backend.Error
  alias Nucleus.NomadVars.Store
  alias Nucleus.NomadVars.VariableSet
  alias Nucleus.Scope

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
end
