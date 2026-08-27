defmodule Nucleus.NomadVars.Store.Local do
  @moduledoc """
  Nomad Variables served from `priv/backends/local_seed.json`.

  A real implementation of `Nucleus.NomadVars.Store`, not a test double — the
  same module serves `mix phx.server` in development and the test suite. A
  fresh clone needs no Nomad ACL token to exercise Data Export configuration
  at all.

  ## State lives in `Nucleus.Backend.Seed`, not a second `Agent`

  Reads and writes go through `Seed.read/1`/`Seed.update/2`, keyed on this
  boundary's `"nomad_vars"` section — the same reasoning
  `Nucleus.Secrets.Store.Local` and `Nucleus.M2M.Clients.Local` document for
  their own sections.

  ## The seed section's shape mirrors one real Nomad API call

      {
        "path": "nomad/jobs/local-data_export",
        "items": {"description": "...", "env_names": "prod,staging"},
        "modify_index": 42,
        "modified_at": "2026-08-01T03:00:00Z"
      }

  The same four fields `GET /v1/var/:path` returns (`Path`, `Items`,
  `ModifyIndex`, `ModifyTime`), so a fixture here exercises the same shape
  `Nucleus.NomadVars.Store.Http` decodes from a real response.

  ## "Not configured" vs. "not enabled" — how they are actually distinguished

  Decision 5 wants two distinct signals: Nucleus itself has no usable Nomad
  configuration (`:not_configured`, an ops problem) vs. this tenant does not
  have Data Export enabled (`:not_found`, mirroring Nomad's own `404` for a
  variable path that was never created — `DEX-A01`'s enablement check). The
  two must read as genuinely different states, not two names for the same
  one.

  **Implementation-time correction to this ticket's plan**: the "not
  enabled" sentinel is the JSON literal `false`, not `null`.
  `Nucleus.Backend.Seed.read/2` calls `get_in/2` against the decoded
  document, which returns `nil` both when the `"nomad_vars"` key is entirely
  absent *and* when it is present with a JSON `null` value — the two cannot
  be told apart once decoded, so `null` cannot carry a meaning distinct from
  "absent" through `Seed`'s actual API. `false` can: it round-trips through
  `Seed.read/2` as the boolean `false`, distinguishably non-`nil`. So:

    * `nil` (section absent, or a test explicitly seeds it `nil`) →
      `:not_configured`, matching every other `Local` implementation's
      convention for its own section
    * `false` → `:not_found` — this tenant does not have Data Export enabled
    * anything else is decoded as a `VariableSet.t()`, or, if malformed,
      `:not_configured` (a bad fixture, not an unreachable cluster — the
      same reasoning `Nucleus.NomadJobs.Local` gives its own shape check)

  See `docs/adr/0027-nomad-vars-adapter.md` for the full record.

  ## Check-and-set is enforced here too — atomically, not read-then-write

  `write/2` compares `expected_modify_index` against the seed's own stored
  index before writing anything — a stale value is `{:error, %Error{kind:
  :conflict}}`, the same contract `Nucleus.NomadVars.Store.Http` gives
  against a real `409`. Unlike `Nucleus.Secrets.Store.Local`'s and
  `Nucleus.M2M.Clients.Local`'s writes, which are unconditional (nothing to
  race), this comparison and the resulting write both happen inside a single
  `Nucleus.Backend.Seed.get_and_update/3` call — not a `Seed.read/1` followed
  by a separate `Seed.update/2`, which would let two concurrent writers both
  read the same current index, both pass the check, and have the second
  silently overwrite the first. A successful write bumps the stored index by
  one and replaces `modified_at`.

  ## Faults come first

  Every callback calls `Nucleus.Backend.Faults.maybe_fault/1` before doing
  anything else, so `LOCAL_FORCE_ERROR=conflict` makes a stale-write retry
  path testable without racing a second real writer.
  """

  @behaviour Nucleus.NomadVars.Store

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Faults
  alias Nucleus.Backend.Seed
  alias Nucleus.NomadVars.Store
  alias Nucleus.NomadVars.VariableSet

  @impl Store
  def read do
    with :ok <- Faults.maybe_fault(Store.boundary()),
         {:ok, section} <- section() do
      {:ok, variable_set(section)}
    end
  end

  @impl Store
  def write(items, expected_modify_index) do
    with :ok <- Faults.maybe_fault(Store.boundary()) do
      Seed.get_and_update(Store.boundary(), fn raw ->
        with {:ok, section} <- interpret(raw),
             :ok <- ensure_matching_index(section, expected_modify_index) do
          updated = bump(section, items)
          {{:ok, variable_set(updated)}, updated}
        else
          {:error, _reason} = error -> {error, raw}
        end
      end)
    end
  end

  @impl Store
  def health_check do
    with :ok <- Faults.maybe_fault(Store.boundary()) do
      case section() do
        {:ok, _section} ->
          :ok

        # Reachability, not enablement — the same reasoning
        # Nucleus.NomadVars.Store.Http.health_check/0 states. A tenant
        # without Data Export enabled still means the seed itself is fine.
        {:error, %Error{kind: :not_found}} ->
          :ok

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  defp section do
    Store.boundary() |> Seed.read() |> interpret()
  end

  defp interpret(raw) do
    case raw do
      false ->
        {:error, error(:not_found, "this tenant does not have Data Export enabled", %{})}

      nil ->
        {:error,
         error(:not_configured, ~s(the backend seed has no "nomad_vars" section), %{
           seed_path: Seed.default_path()
         })}

      %{"path" => path, "items" => items, "modify_index" => modify_index} = valid
      when is_binary(path) and is_map(items) and is_integer(modify_index) ->
        {:ok, valid}

      other ->
        {:error,
         error(:not_configured, ~s(the seed's "nomad_vars" section is malformed), %{
           section: inspect(other)
         })}
    end
  end

  defp ensure_matching_index(%{"modify_index" => current}, expected) when current == expected do
    :ok
  end

  defp ensure_matching_index(%{"modify_index" => current}, _expected) do
    {:error,
     error(:conflict, "the modify index is stale", %{
       modify_index: current
     })}
  end

  defp bump(current, items) do
    %{
      current
      | "items" => items,
        "modify_index" => current["modify_index"] + 1,
        "modified_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp variable_set(%{"path" => path, "items" => items, "modify_index" => modify_index} = section) do
    %VariableSet{
      path: path,
      items: items,
      modify_index: modify_index,
      modified_at: parse_datetime(section["modified_at"])
    }
  end

  defp parse_datetime(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_other), do: nil

  defp error(kind, message, details) do
    Error.new(kind, Store.boundary(), message, details)
  end
end
