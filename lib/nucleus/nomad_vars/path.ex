defmodule Nucleus.NomadVars.Path do
  @moduledoc """
  The one place a Nomad Variables path — and its matching job name — is built.

  Confirmed pattern (this ticket's Decision 1):

      nomad/jobs/{TENANT_NAMESPACE}-data_export

  Wiki `ADR-0006` states this path twice with different placeholder names
  (`{namespace}` and `{deployment}`) — genuinely the same value,
  `Nucleus.Scope.tenant_namespace/0`, per the glossary at
  `docs/requirements/Home.md:66` ("used as a prefix for Nomad jobs/**variables**
  ... no longer used for Parameter Store paths"). `{deployment}` is stale text
  left over from before the Parameter Store migration to
  `CLUSTER_NAME`/`DEPLOYMENT_NAME` — corrected in the wiki by DEX-D1, not here.

  ## Read at call time, not compile time

  Same reasoning `Nucleus.M2M.ClientName.prefix/0` and `Nucleus.Secrets.Path`
  give for their own per-call reads: `Nucleus.Scope.tenant_namespace/0` reads
  application configuration on every call, so a test that overrides
  `TENANT_NAMESPACE` mid-suite sees the new value without a recompile.

  ## `job_name/0` is not a separate construction

  The convention that a `nomad/jobs/<job-id>` variable path is readable by the
  job of that same ID (via a template block) pins `job_name/0` to exactly the
  suffix of `path/0` — `"\#{tenant_namespace}-data_export"`. DEX-S5 filters
  `Nucleus.NomadJobs.list/1`'s results by this name rather than a hardcoded
  literal, and this ticket's seed fixture (`priv/backends/local_seed.json`) is
  named to match.
  """

  alias Nucleus.Scope

  @doc """
  The Nomad Variables path for this tenant's Data Export configuration.

      iex> Application.put_env(:nucleus, Nucleus.Scope, tenant_namespace: "acme")
      iex> Nucleus.NomadVars.Path.path()
      "nomad/jobs/acme-data_export"
  """
  @spec path() :: String.t()
  def path, do: "nomad/jobs/" <> job_name()

  @doc """
  The Data Export job's own name — the suffix of `path/0`, matching the
  `nomad/jobs/<job-id>` convention that makes the variable readable by the job
  of that ID.

      iex> Application.put_env(:nucleus, Nucleus.Scope, tenant_namespace: "acme")
      iex> Nucleus.NomadVars.Path.job_name()
      "acme-data_export"
  """
  @spec job_name() :: String.t()
  def job_name, do: Scope.tenant_namespace() <> "-data_export"
end
