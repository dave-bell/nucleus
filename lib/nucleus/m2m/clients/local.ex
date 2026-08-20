defmodule Nucleus.M2M.Clients.Local do
  @moduledoc """
  Cognito App Clients served from `priv/backends/local_seed.json`.

  A real implementation of `Nucleus.M2M.Clients`, not a test double — the
  same module serves `mix phx.server` in development and the test suite. A
  fresh clone needs no Terraform-provisioned role to exercise this feature at
  all.

  ## State lives in `Nucleus.Backend.Seed`, not a second `Agent`

  Reads and writes go through `Seed.read/1` and `Seed.update/2`, keyed on
  this boundary's `"m2m"` section — the same reasoning
  `Nucleus.Secrets.Store.Local` documents for its own `"secrets"` section: a
  second process offering the same "hold state, offer get/update" shape
  would be a competing local-state mechanism for no benefit.

  ## The seed section's shape

  A map keyed by `client_id`, not a list — `client_id` is the real
  identifier (Cognito does not require `client_name` to be unique, so two
  entries can carry the same name):

      {
        "m2m": {
          "<client_id>": {
            "client_name": "...",
            "scope": "...",
            "token_validity_seconds": 900,
            "created_date": "2026-06-01T12:00:00Z",
            "secrets": [{"value": "...", "created_date": "..."}]
          }
        }
      }

  `list_clients/0` and `describe_client/1` return every entry exactly as
  seeded, **unfiltered** — deny-list matching and tenant-namespace scoping
  are M2M-S1's job, deliberately above this boundary (see
  `Nucleus.M2M.Clients`'s moduledoc). A local implementation that quietly
  filtered here would hide a bug in that gate rather than exposing it.

  ## `rotate_secret/1` actually models two secrets

  `secrets` is a list, oldest first once sorted by `created_date`: rotation
  drops the oldest when two already exist, then appends a freshly generated
  one, matching Cognito's own "up to two active secrets" model exactly (see
  `Nucleus.M2M.Clients.Cognito`'s moduledoc). Returning a fresh random string
  with no memory of the previous one would make M2M-S6's "the previous
  secret is still valid after one rotation, gone after two" assertions
  vacuous against this implementation.

  ## No duplicate-name rejection

  `create_client/2` always creates, matching `Cognito`'s real behaviour —
  see the
  [decision](https://github.com/dave-bell/nucleus/issues/33#issuecomment-5350191153)
  removing `M2M-A09`. `client_id` is generated fresh on every call, so two
  calls with the same `client_name` produce two distinct clients, same as a
  real pool would.

  ## Faults come first

  Every callback calls `Nucleus.Backend.Faults.maybe_fault/1` before doing
  anything else, so `LOCAL_FORCE_ERROR=unavailable` makes this boundary's
  failure paths testable without a real Cognito outage.

  ## Fixtures, not a real pool

  `client_id` and `client_secret` are generated locally — there is no real
  Cognito user pool behind this implementation, so nothing here needs to
  resemble AWS's own ID format beyond "plausible enough to copy and paste."
  """

  @behaviour Nucleus.M2M.Clients

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Faults
  alias Nucleus.Backend.Seed
  alias Nucleus.M2M.Client
  alias Nucleus.M2M.ClientCredentials
  alias Nucleus.M2M.ClientDetail
  alias Nucleus.M2M.Clients

  @impl Clients
  def list_clients do
    with :ok <- Faults.maybe_fault(Clients.boundary()),
         {:ok, entries} <- entries() do
      {:ok, entries |> Enum.map(&to_client/1) |> Enum.sort_by(& &1.client_name)}
    end
  end

  @impl Clients
  def describe_client(client_id) do
    with :ok <- Faults.maybe_fault(Clients.boundary()),
         {:ok, entries} <- entries(),
         {:ok, entry} <- fetch_entry(entries, client_id) do
      {:ok, to_detail(client_id, entry)}
    end
  end

  @impl Clients
  def create_client(client_name, settings) do
    with :ok <- Faults.maybe_fault(Clients.boundary()),
         {:ok, minutes} <- validate_token_validity(settings) do
      {:ok, put_new_entry(client_name, minutes)}
    end
  end

  @impl Clients
  def rotate_secret(client_id) do
    with :ok <- Faults.maybe_fault(Clients.boundary()),
         {:ok, entries} <- entries(),
         {:ok, entry} <- fetch_entry(entries, client_id) do
      {:ok, rotate_entry(client_id, entry)}
    end
  end

  @impl Clients
  def health_check do
    with :ok <- Faults.maybe_fault(Clients.boundary()),
         {:ok, _entries} <- entries() do
      :ok
    end
  end

  # -- Reads ------------------------------------------------------------

  defp entries do
    case Seed.read(Clients.boundary()) do
      %{} = entries ->
        {:ok, entries}

      nil ->
        {:error,
         error(:not_configured, ~s(the backend seed has no "m2m" section), %{
           seed_path: Seed.default_path()
         })}

      other ->
        {:error,
         error(:not_configured, ~s(the seed's "m2m" section is not a map), %{
           section: inspect(other)
         })}
    end
  end

  defp fetch_entry(entries, client_id) do
    case Map.get(entries, client_id) do
      %{} = entry -> {:ok, entry}
      _absent -> {:error, error(:not_found, "no such client", %{client_id: client_id})}
    end
  end

  defp to_client({client_id, entry}) do
    %Client{
      client_id: client_id,
      client_name: entry["client_name"],
      created_date: parse_datetime(entry["created_date"]),
      created_date_error: nil
    }
  end

  defp to_detail(client_id, entry) do
    %ClientDetail{
      client_id: client_id,
      client_name: entry["client_name"],
      scope: entry["scope"],
      token_validity_seconds: entry["token_validity_seconds"],
      created_date: parse_datetime(entry["created_date"])
    }
  end

  # -- create_client/2 ---------------------------------------------------

  defp validate_token_validity(settings) do
    range = Clients.token_validity_range()
    minutes = Keyword.get(settings, :token_validity_minutes)

    if is_integer(minutes) and minutes in range do
      {:ok, minutes}
    else
      {:error,
       error(
         :invalid,
         "token_validity_minutes must be a whole number of minutes from " <>
           "#{range.first} to #{range.last} inclusive, got: #{inspect(minutes)}"
       )}
    end
  end

  defp put_new_entry(client_name, minutes) do
    client_id = generate_client_id()
    secret = generate_secret()
    now = DateTime.utc_now()

    entry = %{
      "client_name" => client_name,
      "scope" => "#{Nucleus.Scope.tenant_namespace()}/api",
      "token_validity_seconds" => minutes * 60,
      "created_date" => DateTime.to_iso8601(now),
      "secrets" => [%{"value" => secret, "created_date" => DateTime.to_iso8601(now)}]
    }

    Seed.update(Clients.boundary(), fn m2m ->
      m2m = m2m || %{}
      Map.put(m2m, client_id, entry)
    end)

    %ClientCredentials{client_id: client_id, client_name: client_name, client_secret: secret}
  end

  # -- rotate_secret/1 ----------------------------------------------------
  #
  # Mirrors Cognito's own sequence: delete the oldest secret if two already
  # exist (never if only one does), then append a freshly generated one — so
  # the previous secret survives exactly one rotation, never two.
  defp rotate_entry(client_id, entry) do
    now = DateTime.utc_now()
    new_secret = %{"value" => generate_secret(), "created_date" => DateTime.to_iso8601(now)}

    kept =
      case Map.get(entry, "secrets", []) do
        [_, _ | _] = secrets -> secrets |> Enum.sort_by(& &1["created_date"]) |> Enum.drop(1)
        secrets -> secrets
      end

    updated_entry = Map.put(entry, "secrets", kept ++ [new_secret])

    Seed.update(Clients.boundary(), fn m2m ->
      m2m = m2m || %{}
      Map.put(m2m, client_id, updated_entry)
    end)

    %ClientCredentials{
      client_id: client_id,
      client_name: entry["client_name"],
      client_secret: new_secret["value"]
    }
  end

  # -- Shape helpers ------------------------------------------------------

  defp generate_client_id, do: 13 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  defp generate_secret, do: 32 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp parse_datetime(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_other), do: nil

  defp error(kind, message, details \\ %{}) do
    Error.new(kind, Clients.boundary(), message, details)
  end
end
