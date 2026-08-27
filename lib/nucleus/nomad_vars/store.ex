defmodule Nucleus.NomadVars.Store do
  @moduledoc """
  The boundary to Nomad Variables backing Data Export configuration
  (`docs/requirements/Data-Export-Configuration.md`) — read **and** update,
  deliberately separate from `Nucleus.NomadJobs`'s read-only job data. See
  `docs/adr/0022-nomad-jobs-adapter.md`, Decision 7: job reads and Nomad
  Variables are different capabilities with different access levels, and
  collapsing them into one boundary would put a write callback on the same
  switch as `APP-A08`'s read-only guarantee.

  Two implementations, selected per boundary by `NOMAD_VARS_BACKEND` — see
  `Nucleus.Backend`:

  | Mode | Module | |
  |---|---|---|
  | `real` | `Nucleus.NomadVars.Store.Http` | `Nucleus.Nomad.Transport` against the tenant's Nomad cluster |
  | `local` | `Nucleus.NomadVars.Store.Local` | `priv/backends/local_seed.json` |

  One behaviour, read + write — following `Nucleus.Secrets.Store` and
  `Nucleus.M2M.Clients`'s shape, not a read-behaviour/write-behaviour split.

  ## Call through this module, not an implementation

  `read/0`, `write/2`, and `health_check/0` resolve the implementation on
  every call, through `Nucleus.Backend.impl_for/1`. Nothing outside this
  module should name `Http` or `Local`.

  ## No create or delete callback, of any kind

  The requirement is explicit that the variable path already exists for any
  tenant with Data Export enabled — this boundary is read-**and-update**-only,
  by construction, in the terms `Nucleus.NomadJobs`'s "no create, update, or
  delete callback of any kind" states its own omission, inverted.

  ## `write/2` replaces the entire `Items` map

  Nomad's `PUT /v1/var/:path` replaces the whole object — there is no partial
  update on the wire. `write/2` mirrors that: it takes the entire desired
  `Items` map, not a single key/value pair. The caller (a future
  `Nucleus.NomadVars` context module, DEX-S2/DEX-S4) is responsible for
  starting from a freshly-read `Items` map and changing only the key(s) it
  means to change — this boundary does not merge on the caller's behalf, and
  must not silently do so. A merge here would hide exactly the clobbering
  behaviour check-and-set exists to catch (see `expected_modify_index` below).

  ## `expected_modify_index` is check-and-set, not optimistic decoration

  Nomad Variables are path-addressed: one path holds an `Items` map for every
  key, with a single `ModifyIndex` for the whole path. A single-key write is a
  read-modify-write of that whole map — without check-and-set, two edits to
  *different* keys race and silently clobber each other. `write/2` always
  requires the modify index the caller's most recent `read/0` returned;
  a stale value is `{:error, %Error{kind: :conflict}}`, never a silent
  overwrite.

  ## `read/0`'s `:not_found` is Data Export's enablement signal

  Nomad's `GET /v1/var/:path` 404s when the path has never been created.
  `read/0` surfaces that 404 as `{:error, %Error{kind: :not_found}}` — this
  *is* "Data Export is not enabled for this tenant" (`DEX-A01`), not a
  separate status probe. Distinct from `:not_configured`, which means Nucleus
  itself has no usable Nomad configuration (a deployment mistake), not that
  this particular tenant lacks the feature.
  """

  alias Nucleus.Backend
  alias Nucleus.Backend.Error
  alias Nucleus.NomadVars.VariableSet

  @boundary :nomad_vars

  @doc """
  Reads the current `Items` map and modify index for this tenant's Data
  Export variable path.

  `{:error, %Error{kind: :not_found}}` when the path has never been created —
  Data Export is not enabled for this tenant (`DEX-A01`).
  """
  @callback read() :: {:ok, VariableSet.t()} | {:error, Error.t()}

  @doc """
  Replaces the path's entire `Items` map with `items`, if `expected_modify_index`
  still matches the path's current modify index.

  `{:error, %Error{kind: :conflict}}` when `expected_modify_index` is stale —
  the path changed since the caller's last `read/0`. Never merges `items`
  with what is already stored; the caller supplies the complete desired map.
  """
  @callback write(
              items :: %{String.t() => String.t()},
              expected_modify_index :: non_neg_integer()
            ) ::
              {:ok, VariableSet.t()} | {:error, Error.t()}

  @doc """
  Whether this boundary can reach the system behind it.
  """
  @callback health_check() :: :ok | {:error, Error.t()}

  @doc """
  The boundary name, for `Nucleus.Backend` and error construction.
  """
  @spec boundary() :: atom()
  def boundary, do: @boundary

  @doc """
  Reads this tenant's Data Export variable set through the configured
  implementation.
  """
  @spec read() :: {:ok, VariableSet.t()} | {:error, Error.t()}
  def read, do: impl().read()

  @doc """
  Replaces the entire `Items` map, enforcing check-and-set against
  `expected_modify_index`.
  """
  @spec write(%{String.t() => String.t()}, non_neg_integer()) ::
          {:ok, VariableSet.t()} | {:error, Error.t()}
  def write(items, expected_modify_index)
      when is_map(items) and is_integer(expected_modify_index) and expected_modify_index >= 0 do
    impl().write(items, expected_modify_index)
  end

  @doc """
  Checks the configured implementation can reach Nomad.
  """
  @spec health_check() :: :ok | {:error, Error.t()}
  def health_check, do: impl().health_check()

  defp impl, do: Backend.impl_for(@boundary)
end
