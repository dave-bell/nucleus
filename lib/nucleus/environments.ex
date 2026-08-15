defmodule Nucleus.Environments do
  @moduledoc """
  The fail-closed validation ladder every Secrets action mounts through
  (`SEC-A15`, `SEC-A16`, `SEC-A17`).

  Nucleus is not authoritative for environments — `Nucleus.TenantApi` is —
  but a raw, caller-supplied environment name reaches this module before it
  reaches anything that builds a Parameter Store path
  (`Nucleus.Secrets.Path.build/2` assumes it never sees an unvalidated one).
  This module is the only gate.

  Two functions, deliberately separated:

  - `validate_name/1` is pure. No I/O, cannot be skipped by a network fault,
    and is cheap enough to run before anything else — `SEC-A15` requires a
    path-traversal name be rejected "before any lookup is attempted".
  - `fetch/2` is the whole ladder: validate, then call out to
    `Nucleus.TenantApi.list_environments/1`, then resolve. `validate_name/1`
    is called as `fetch/2`'s first statement so an invalid name causes zero
    adapter calls — this is asserted directly in
    `test/nucleus/environments_test.exs`, not merely inferred from behaviour.

  ## Allowlist, not denylist

  The wiki's error matrix only names `..`, `/`, `\\` as deny cases, but a
  three-sequence denylist lets percent-encoded traversal, unicode
  lookalikes, and control characters through — the same class of problem
  `PRX-A04` calls out for the proxy allowlist. `validate_name/1` rejects
  anything that fails a positive charset check
  (`~r/\\A[a-z0-9][a-z0-9-]*\\z/`) rather than trying to enumerate what to
  reject.

  Phoenix has already percent-decoded a path segment by the time it reaches
  `handle_params/3`, so `%2e%2e` arrives as `..` and would be caught by a
  denylist too — but `%252e` (double-encoded) arrives as `%2e`, which the
  denylist would miss and this allowlist rejects outright, since `%` is not
  in the allowed charset.

  ## No cache, no fallback — ever

  `SEC-A17`'s precondition is "the backing API is unreachable, **and no
  cached list is available**". With the stateless constraint (EN-1), that is
  the only state that ever exists — `fetch/2` never caches
  `list_environments/1`'s result and never falls back to a stale list on
  failure. Adding either would create an untested second path and weaken the
  fail-closed guarantee this module exists to provide.

  ## Archived environments resolve too

  `ENV-A06` requires an archived environment stay reachable by direct URL and
  usable for secrets management. `fetch/2` matches against every environment
  `list_environments/1` returns, archived included — filtering archived ones
  out of navigation is `NucleusWeb.EnvironmentsHook`'s job, not this one's.
  """

  alias Nucleus.Backend.Error
  alias Nucleus.TenantApi
  alias Nucleus.TenantApi.Environment

  @boundary :tenant_api
  @max_length 64
  @allowed_name ~r/\A[a-z0-9][a-z0-9-]*\z/

  @doc """
  Validates `name` as a well-formed environment short name.

  Pure — performs no I/O and calls no adapter. Returns `:ok` or
  `{:error, %Nucleus.Backend.Error{kind: :invalid}}`.

  Rejects: anything that is not a binary, an empty string, a name containing
  `..` anywhere, a name containing `/` or `\\`, a name containing a null
  byte, a name longer than #{@max_length} characters, and anything that
  fails the positive charset allowlist (lowercase letters, digits, and
  internal hyphens; must start with a letter or digit).

      iex> Nucleus.Environments.validate_name("prod")
      :ok

      iex> {:error, error} = Nucleus.Environments.validate_name("..")
      iex> error.kind
      :invalid

      iex> {:error, error} = Nucleus.Environments.validate_name(nil)
      iex> error.kind
      :invalid
  """
  @spec validate_name(term()) :: :ok | {:error, Error.t()}
  def validate_name(name) when is_binary(name) do
    cond do
      name == "" ->
        invalid(name)

      String.contains?(name, "..") ->
        invalid(name)

      String.contains?(name, "/") or String.contains?(name, "\\") ->
        invalid(name)

      String.contains?(name, <<0>>) ->
        invalid(name)

      String.length(name) > @max_length ->
        invalid(name)

      not Regex.match?(@allowed_name, name) ->
        invalid(name)

      true ->
        :ok
    end
  end

  def validate_name(name), do: invalid(name)

  @doc """
  Validates, fetches, and resolves `name` to the tenant's environment.

  Strict order, which is the substance of `SEC-A15`:

  1. `validate_name/1` — on error, returns immediately. No adapter call, no
     path construction.
  2. `Nucleus.TenantApi.list_environments/1` — an `:unavailable` or
     `:not_configured` error is returned as `:unavailable` (`SEC-A17`);
     an `:auth_expired` error passes through unchanged, untouched by this
     module (`SEC-S7`'s concern).
  3. Resolves by exact `short_name` match, archived environments included
     (`ENV-A06`). No match is `{:error, kind: :not_found}` (`SEC-A16`).

  Never caches the list and never falls back to a stale one — see the
  module doc.
  """
  @spec fetch(term(), String.t() | nil) :: {:ok, Environment.t()} | {:error, Error.t()}
  def fetch(name, token) do
    with :ok <- validate_name(name) do
      resolve(TenantApi.list_environments(token), name)
    end
  end

  defp resolve({:ok, environments}, name) do
    case Enum.find(environments, &(&1.short_name == name)) do
      nil ->
        {:error,
         Error.new(:not_found, @boundary, "no such environment: #{inspect(name)}", %{
           environment: name
         })}

      environment ->
        {:ok, environment}
    end
  end

  defp resolve({:error, %Error{kind: kind} = error}, _name)
       when kind in [:unavailable, :not_configured] do
    {:error,
     Error.new(:unavailable, @boundary, "environment validation is unavailable", %{
       reason: error.message
     })}
  end

  defp resolve({:error, %Error{} = error}, _name), do: {:error, error}

  defp invalid(name) do
    {:error,
     Error.new(:invalid, @boundary, "invalid environment name", %{
       environment: inspect(name)
     })}
  end
end
