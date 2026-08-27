defmodule Nucleus.BackendCase do
  @moduledoc """
  The one fake per boundary, for tests that exercise `Nucleus.TenantApi` or
  `Nucleus.Secrets.Store` through their local implementations — replacing any
  temptation to hand-roll a per-test double (ADR-0007 §7, wiki).

  `config/test.exs` already selects `Nucleus.TenantApi.Local` and
  `Nucleus.Secrets.Store.Local` as `:backends`, so this case does not need to
  set that config itself. What it wraps is the *state* those implementations
  read and write, and the fault-injection knobs they check on every call.

  ## Not per-test — deliberately

  This ticket's plan originally hoped for a per-test-process seed, safe under
  `async: true`. That is not what EN-3/EN-4 built, and issue #8's own comment
  thread confirms the divergence deliberately: `Nucleus.Backend.Seed` is one
  globally-named `Agent`, started in the supervision tree in every
  environment (`docs/adr/0003-shared-local-backend-seed.md`), and
  `Nucleus.Secrets.Store.Local` has no `Agent` of its own — it reads and
  mutates through that same global seed
  (`docs/adr/0007-secrets-store-adapter.md`). `LOCAL_FORCE_ERROR` and
  `LOCAL_LATENCY_MS` (`Nucleus.Backend.Faults`) are node-global environment
  variables for the same reason.

  A case built on global, mutable, node-wide state cannot be `async: true`
  safe — any test that seeds, mutates, or injects a fault must run
  `async: false`, matching the precedent already set by
  `test/nucleus/tenant_api/local_test.exs` and
  `test/nucleus/secrets/store/local_test.exs`. This case's own `setup` resets
  that state unconditionally in `on_exit`, so leakage between tests is
  structurally prevented — but only serialised tests can rely on it.

      defmodule MyTest do
        use Nucleus.BackendCase, async: false

        test "..." do
          seed_secret("prod", "API_KEY", "shh")
          ...
        end
      end
  """

  use ExUnit.CaseTemplate

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Seed

  @force_error_var "LOCAL_FORCE_ERROR"
  @latency_var "LOCAL_LATENCY_MS"

  using do
    quote do
      import Nucleus.BackendCase
    end
  end

  setup do
    on_exit(fn ->
      Seed.reset()
      Nucleus.BackendCase.clear_faults()
    end)

    :ok
  end

  @doc """
  Seeds (or replaces) one secret's value in `environment`, under the
  `Nucleus.Secrets.Store.Local` boundary — the same `"secrets"` seed section
  `docs/adr/0007-secrets-store-adapter.md` documents.

  Writes directly through `Nucleus.Backend.Seed.update/2`, bypassing
  `Nucleus.Secrets.Store.create_secret/3`'s already-exists check, so a test
  can set up a fixture regardless of whether the key already exists.
  """
  @spec seed_secret(String.t(), String.t(), String.t()) :: :ok
  def seed_secret(environment, key, value)
      when is_binary(environment) and is_binary(key) and is_binary(value) do
    entry = %{"value" => value, "last_modified" => DateTime.to_iso8601(DateTime.utc_now())}

    Seed.update(:secrets, fn secrets ->
      secrets = secrets || %{}
      bucket = Map.get(secrets, environment, %{})
      Map.put(secrets, environment, Map.put(bucket, key, entry))
    end)
  end

  @doc """
  Appends one environment to the `Nucleus.TenantApi.Local` boundary's seeded
  list.

  `attrs` is the same camelCase shape the seed file and the backing API use
  (`Nucleus.TenantApi.Environment.from_api/1`) — e.g.
  `%{"shortName" => "qa", "label" => "QA"}` — not the translated
  `%Environment{}` struct, so a test fixture matches what a real API would
  actually send.
  """
  @spec seed_environment(map()) :: :ok
  def seed_environment(%{} = attrs) do
    Seed.update(:tenant_api, fn tenant_api ->
      tenant_api = tenant_api || %{}
      environments = Map.get(tenant_api, "environments", [])
      Map.put(tenant_api, "environments", environments ++ [attrs])
    end)
  end

  @doc """
  Appends one entry to the `Nucleus.NomadJobs.Local` boundary's seeded list.

  `attrs` is `%{"stub" => ..., "detail" => ...}` — the same two
  Nomad-shaped maps `Nucleus.NomadJobs.Job.from_api/3` and `.child?/1`
  consume, matching the seed file's own shape
  (`Nucleus.NomadJobs.Local`'s moduledoc).
  """
  @spec seed_nomad_job(map()) :: :ok
  def seed_nomad_job(%{"stub" => %{}, "detail" => %{}} = attrs) do
    Seed.update(:nomad_jobs, fn nomad_jobs ->
      nomad_jobs = nomad_jobs || []
      nomad_jobs ++ [attrs]
    end)
  end

  @doc """
  Replaces the `Nucleus.NomadVars.Store.Local` boundary's seeded section.

  `attrs` is `%{"path" => ..., "items" => ..., "modify_index" => ...,
  "modified_at" => ...}` — the same shape `Nucleus.NomadVars.Store.Http`
  decodes from a real `GET /v1/var/:path` response, matching the seed
  file's own shape (`Nucleus.NomadVars.Store.Local`'s moduledoc).

  Replaces rather than appends — unlike `seed_nomad_job/1`'s list, this
  boundary's section is a single object, one path per tenant.
  """
  @spec seed_nomad_var(map()) :: :ok
  def seed_nomad_var(%{"path" => path, "items" => %{}, "modify_index" => modify_index} = attrs)
      when is_binary(path) and is_integer(modify_index) do
    Seed.write(:nomad_vars, attrs)
  end

  @doc """
  Makes every local backend implementation return `{:error, %Error{kind: kind}}`
  on its next call, via `LOCAL_FORCE_ERROR` (`Nucleus.Backend.Faults`).

  `boundary` is accepted for symmetry with `seed_secret/3`/`seed_environment/1`
  and to make call sites self-documenting, but the underlying fault is
  node-global today — every local implementation checks the same environment
  variable, regardless of which boundary is passed here. Raises on an unknown
  `kind`, the same as `Nucleus.Backend.Faults` does, rather than silently
  arming no fault.
  """
  @spec force_error(atom(), Error.kind()) :: :ok
  def force_error(boundary, kind) when is_atom(boundary) and is_atom(kind) do
    unless kind in Error.kinds() do
      raise ArgumentError,
            "unknown Nucleus.Backend.Error kind #{inspect(kind)}. " <>
              "Valid kinds: #{inspect(Error.kinds())}"
    end

    System.put_env(@force_error_var, Atom.to_string(kind))
    :ok
  end

  @doc """
  Clears any fault armed by `force_error/2`, plus `LOCAL_LATENCY_MS`, so a
  test that does not call this itself (via `on_exit`) cannot leak a fault
  into whatever runs next.
  """
  @spec clear_faults() :: :ok
  def clear_faults do
    System.delete_env(@force_error_var)
    System.delete_env(@latency_var)
    :ok
  end
end
