defmodule Nucleus.NomadVars.Store.Http do
  @moduledoc """
  Nomad Variables over HTTP, using `Nucleus.Nomad.Transport` — the same
  shared transport `Nucleus.NomadJobs.Http` uses, unchanged
  (`docs/adr/0022-nomad-jobs-adapter.md`, Decision 7's own consequence).

  ## One path per tenant

  Every call is against `Nucleus.NomadVars.Path.path/0` — there is no
  per-call path argument, since this boundary only ever addresses the one
  variable path Data Export uses for this tenant.

  ## `read/0`'s `404` is not swallowed

  `Transport.request/3` already maps a Nomad `404` to
  `{:error, %Error{kind: :not_found}}` — this is `DEX-A01`'s enablement
  signal (see `Nucleus.NomadVars.Store`'s moduledoc), so it passes straight
  through rather than being caught and re-shaped here.

  ## `write/2` always sends `cas`

  `Transport.request/3` already maps a Nomad `409` to
  `{:error, %Error{kind: :conflict}}`, carrying the fresh `ModifyIndex` in
  `details` when Nomad's own conflict response includes one. `write/2` sends
  `expected_modify_index` as the `cas` query parameter on every call — there
  is no unconditional-write code path.

  ## A successful write's response is read back into a `VariableSet`

  Nomad's `PUT /v1/var/:path` returns the updated variable object on success
  (the same shape `GET` returns), so both callbacks share `variable_set/1`.
  On the rare case the write response body is empty (`Nucleus.Nomad.Transport`
  now decodes that to `{:ok, %{}}` rather than erroring), this falls back to
  a fresh `read/0` rather than fabricating a `ModifyIndex`.
  """

  @behaviour Nucleus.NomadVars.Store

  alias Nucleus.Backend.Error
  alias Nucleus.Nomad.Transport
  alias Nucleus.NomadVars.Path
  alias Nucleus.NomadVars.Store
  alias Nucleus.NomadVars.VariableSet

  @impl Store
  def read do
    case Transport.request(:get, request_path(), boundary: Store.boundary()) do
      {:ok, %{"ModifyIndex" => _} = body} ->
        {:ok, variable_set(body)}

      {:ok, _other} ->
        {:error, error(:unavailable, "nomad returned an unexpected shape for /v1/var")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl Store
  def write(items, expected_modify_index) do
    case Transport.request(:put, request_path(),
           boundary: Store.boundary(),
           query: [cas: expected_modify_index],
           json: %{"Items" => items}
         ) do
      {:ok, %{"ModifyIndex" => _} = body} ->
        {:ok, variable_set(body)}

      {:ok, empty} when empty == %{} ->
        read()

      {:ok, _other} ->
        {:error, error(:unavailable, "nomad returned an unexpected shape for /v1/var")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl Store
  def health_check do
    case read() do
      {:ok, _variable_set} -> :ok
      # Reachability, not permission or enablement — the same reasoning
      # Nucleus.NomadJobs.Http.health_check/0 states. A well-formed-but-
      # unenabled tenant (:not_found) still means Nomad answered.
      {:error, %Error{kind: kind}} when kind in [:auth_expired, :not_found] -> :ok
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp request_path, do: "/v1/var/" <> URI.encode(Path.path())

  defp variable_set(body) do
    %VariableSet{
      path: Map.get(body, "Path", Path.path()),
      items: Map.get(body, "Items") || %{},
      modify_index: Map.fetch!(body, "ModifyIndex"),
      modified_at: modified_at(body["ModifyTime"])
    }
  end

  defp modified_at(nanoseconds) when is_integer(nanoseconds) do
    DateTime.from_unix!(nanoseconds, :nanosecond)
  end

  defp modified_at(_absent_or_invalid), do: nil

  defp error(kind, message, details \\ %{}) do
    Error.new(kind, Store.boundary(), message, details)
  end
end
