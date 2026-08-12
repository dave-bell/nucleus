defmodule Nucleus.Secrets.Store.Local do
  @moduledoc """
  Parameter Store served from `priv/backends/local_seed.json`.

  This is what makes a fresh clone runnable without a Terraform-provisioned
  cross-account IAM role — wiki ADR-0007's specific pain. It is a real
  implementation of `Nucleus.Secrets.Store`, not a test double: the same
  module serves `mix phx.server` in development and the test suite.

  ## State lives in `Nucleus.Backend.Seed`, not a second `Agent`

  EN-4's original plan called for its own supervised `Agent`. That was
  reversed once `Nucleus.Backend.Seed` (built by EN-3) turned out to already
  be a supervised, mutable, boundary-neutral seed owner: a second process
  offering the same "hold state, offer get/update" shape would be two
  competing local-state mechanisms for no benefit. Reads and writes go through
  `Seed.read/1`, `Seed.update/2`, keyed on this boundary's `"secrets"` section.

  ## The fixtures are deliberate

  | Bucket | Exercises |
  |---|---|
  | `prod` | several secrets, including one 4096-character value (`SEC-A11`) |
  | `sandbox` | zero secrets — the empty state (`SEC-A14`) |
  | `shared` | at least one entry — a genuinely manageable bucket, not the runtime fallback the wiki describes (that resolution logic belongs to the function service, not Nucleus) |

  Bucket names are **not** required to match `Nucleus.TenantApi`'s seeded
  environments — this boundary is decoupled from the tenant API (see
  `Nucleus.Secrets.Path`).

  ## The real error contract is reproduced, not approximated

  `create_secret/3` rejects an existing key (`:already_exists`, never
  overwrites) and `update_secret/3` rejects a missing one (`:not_found`, never
  creates) — the same two rules `Nucleus.Secrets.Store.Aws` enforces against
  Parameter Store itself. A local implementation that got this wrong would
  make the shared contract tests worthless.

  ## Faults come first

  Every callback calls `Nucleus.Backend.Faults.maybe_fault/1` before doing
  anything else, so `LOCAL_FORCE_ERROR=auth_expired` makes `SEC-S7` testable
  without a real expired AWS session.

  ## Synthesised, plausible-looking path and ARN

  `path` comes from `Nucleus.Secrets.Path.build/2`, the same function the real
  implementation uses. `arn` is built against a fixed, obviously-fake account
  ID and region — there is no real AWS account behind this implementation —
  so the copy affordances in `SEC-A02` have something realistic to copy
  locally.
  """

  @behaviour Nucleus.Secrets.Store

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Faults
  alias Nucleus.Backend.Seed
  alias Nucleus.Secrets.Secret
  alias Nucleus.Secrets.SecretLocation
  alias Nucleus.Secrets.SecretRef
  alias Nucleus.Secrets.Store

  # No real AWS account exists behind this implementation. These are fixed and
  # obviously not a real tenant's account — 123456789012 is AWS's own
  # documentation placeholder account ID.
  @fake_account_id "123456789012"
  @fake_region "us-east-1"

  @impl Store
  def list_secrets(environment) do
    with :ok <- Faults.maybe_fault(Store.boundary()),
         {:ok, buckets} <- buckets() do
      {:ok, refs(environment, Map.get(buckets, environment, %{}))}
    end
  end

  @impl Store
  def get_secret(environment, key) do
    with :ok <- Faults.maybe_fault(Store.boundary()),
         {:ok, buckets} <- buckets(),
         {:ok, entry} <- fetch_entry(buckets, environment, key) do
      {:ok,
       %Secret{
         key: key,
         path: Nucleus.Secrets.Path.build(environment, key),
         arn: arn(environment, key),
         value: entry["value"],
         last_modified: parse_datetime(entry["last_modified"])
       }}
    end
  end

  @impl Store
  def create_secret(environment, key, value) do
    with :ok <- Faults.maybe_fault(Store.boundary()),
         {:ok, buckets} <- buckets(),
         :ok <- ensure_absent(buckets, environment, key) do
      {:ok, put_entry(environment, key, value)}
    end
  end

  @impl Store
  def update_secret(environment, key, value) do
    with :ok <- Faults.maybe_fault(Store.boundary()),
         {:ok, buckets} <- buckets(),
         {:ok, _entry} <- fetch_entry(buckets, environment, key) do
      {:ok, put_entry(environment, key, value)}
    end
  end

  @impl Store
  def locate_secret(environment, key) do
    with :ok <- Faults.maybe_fault(Store.boundary()) do
      {:ok,
       %SecretLocation{
         path: Nucleus.Secrets.Path.build(environment, key),
         arn: arn(environment, key)
       }}
    end
  end

  @impl Store
  def list_environments do
    with :ok <- Faults.maybe_fault(Store.boundary()),
         {:ok, buckets} <- buckets() do
      {:ok, buckets |> Map.keys() |> Enum.sort()}
    end
  end

  @impl Store
  def list_all_secrets do
    with :ok <- Faults.maybe_fault(Store.boundary()),
         {:ok, buckets} <- buckets() do
      all =
        for {environment, bucket} <- buckets,
            ref <- refs(environment, bucket),
            do: %{environment: environment, secret: ref}

      {:ok, all}
    end
  end

  @impl Store
  def health_check do
    with :ok <- Faults.maybe_fault(Store.boundary()),
         {:ok, _buckets} <- buckets() do
      :ok
    end
  end

  defp buckets do
    case Seed.read(Store.boundary()) do
      %{} = secrets ->
        {:ok, secrets}

      nil ->
        {:error,
         error(:not_configured, ~s(the backend seed has no "secrets" section), %{
           seed_path: Seed.default_path()
         })}

      other ->
        {:error,
         error(:not_configured, ~s(the seed's "secrets" section is not a map), %{
           section: inspect(other)
         })}
    end
  end

  defp fetch_entry(buckets, environment, key) do
    case get_in(buckets, [environment, key]) do
      %{} = entry ->
        {:ok, entry}

      _absent ->
        {:error, error(:not_found, "no such secret", %{environment: environment, key: key})}
    end
  end

  defp ensure_absent(buckets, environment, key) do
    case get_in(buckets, [environment, key]) do
      nil ->
        :ok

      _entry ->
        {:error,
         error(:already_exists, "secret already exists", %{environment: environment, key: key})}
    end
  end

  defp put_entry(environment, key, value) do
    now = DateTime.utc_now()

    Seed.update(Store.boundary(), fn secrets ->
      secrets = secrets || %{}
      bucket = Map.get(secrets, environment, %{})
      entry = %{"value" => value, "last_modified" => DateTime.to_iso8601(now)}
      Map.put(secrets, environment, Map.put(bucket, key, entry))
    end)

    %SecretRef{
      key: key,
      path: Nucleus.Secrets.Path.build(environment, key),
      arn: arn(environment, key),
      last_modified: now
    }
  end

  defp refs(environment, bucket) when is_map(bucket) do
    bucket
    |> Enum.map(fn {key, entry} ->
      %SecretRef{
        key: key,
        path: Nucleus.Secrets.Path.build(environment, key),
        arn: arn(environment, key),
        last_modified: parse_datetime(entry["last_modified"])
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp arn(environment, key) do
    "arn:aws:ssm:#{@fake_region}:#{@fake_account_id}:parameter" <>
      Nucleus.Secrets.Path.build(environment, key)
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
