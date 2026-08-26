defmodule Nucleus.NomadJobs.Job do
  @moduledoc """
  One deployed application (`APP-A01`), and the shared translation from
  Nomad's own JSON shapes into that struct.

  `from_api/3` and `child?/1` are called by both `Nucleus.NomadJobs.Http` (a
  real list stub plus a real per-job detail response) and
  `Nucleus.NomadJobs.Local` (one seeded record modelling the same two
  shapes) — the same "translation is shared, not duplicated" precedent
  `Nucleus.TenantApi.Environment.from_api_list/1` sets between
  `Nucleus.TenantApi.Http` and `.Local`. A seed fixture therefore exercises
  the exact same extraction logic a real Nomad response would.

  ## Fields

    * `name`, `status`, `namespace`, `periodic?` — from the list stub.
      `status` is one of Nomad's three documented values (`"pending"`,
      `"running"`, `"dead"`), cast defensively: an unknown value passes
      through as-is rather than crashing.
    * `version` — `Job.Version`, Nomad's scheduler revision integer. A
      revision counter, not a release identifier: it says the jobspec was
      resubmitted, never what changed (`APP-S2`/#59 labels this column "Job
      revision" accordingly). **Not** `Meta.version` — see `version_from/1`.
    * `image` — the container image reference of the task where `Lifecycle
      == nil`. **Not** `Tasks[0]` — see `image_from/1`. `nil` when no task
      qualifies, which is a genuine absence, not a fetch failure.
    * `cron` — the cron spec, or `nil` when `periodic?` is `false`. Never a
      blank string (`APP-A05`).
    * `detail_error` — a `Nucleus.Backend.Error.kind()` or `nil`. Non-nil
      means `version`, `image`, **and** `cron` are all unknown for this row,
      since all three come from the one per-job detail call. Nil means they
      are authoritative.

  See `docs/adr/0022-nomad-jobs-adapter.md` for the decisions behind each of
  these (Decisions 1, 2, 3, 5, 6).
  """

  alias Nucleus.Backend.Error

  @enforce_keys [:name, :status, :namespace, :periodic?]
  defstruct [:name, :status, :version, :namespace, :image, :cron, :periodic?, :detail_error]

  @type t :: %__MODULE__{
          name: String.t(),
          status: String.t(),
          version: non_neg_integer() | nil,
          namespace: String.t(),
          image: String.t() | nil,
          cron: String.t() | nil,
          periodic?: boolean(),
          detail_error: Error.kind() | nil
        }

  @doc """
  Whether `stub` (a Nomad `JobListStub`-shaped map) names a child job that
  must not surface as its own row (`APP-A01`).

  Applies to periodic **and** parameterized/dispatch children alike
  (Decision 4) — any non-blank `ParentID` excludes it, with no knowledge of
  job type needed.
  """
  @spec child?(map()) :: boolean()
  def child?(%{"ParentID" => parent_id}) when is_binary(parent_id), do: parent_id != ""
  def child?(_stub), do: false

  @doc """
  Builds a fully-resolved job from a list stub and its per-job detail
  response.
  """
  @spec from_api(stub :: map(), detail :: map(), namespace :: String.t()) :: t()
  def from_api(stub, detail, namespace) do
    %__MODULE__{
      name: stub["Name"],
      status: stub["Status"],
      namespace: namespace,
      periodic?: periodic?(stub),
      version: version_from(detail),
      image: image_from(detail),
      cron: cron_from(detail),
      detail_error: nil
    }
  end

  @doc """
  Builds a degraded job: the list stub's fields are authoritative, but the
  per-job detail call failed, so `version`, `image`, and `cron` are all
  unknown (Decision 6).
  """
  @spec degraded(stub :: map(), namespace :: String.t(), kind :: Error.kind()) :: t()
  def degraded(stub, namespace, kind) do
    %__MODULE__{
      name: stub["Name"],
      status: stub["Status"],
      namespace: namespace,
      periodic?: periodic?(stub),
      version: nil,
      image: nil,
      cron: nil,
      detail_error: kind
    }
  end

  defp periodic?(%{"Periodic" => true}), do: true
  defp periodic?(_stub), do: false

  # `Job.Version` — Nomad's scheduler revision integer (Decision 1). The list
  # stub carries no `Version` field at all (the prototype's `nomad.py:139`
  # bug read `job.get("Version", 0)` from it and got 0 every time), so this
  # only ever reads the detail response.
  defp version_from(%{"Version" => version}) when is_integer(version), do: version
  defp version_from(_detail), do: nil

  # The task where `Lifecycle == nil` — never `Tasks[0]` (Decision 3).
  # Authored prestart tasks commonly come first in the HCL, and an injected
  # Consul Connect sidecar is appended, so position alone selects the wrong
  # task for a job authored that way (the prototype's `nomad.py:159-166` bug).
  # Prefers `Leader == true` if several tasks qualify, otherwise the first in
  # encounter order. No driver gate and no `Kind` filter: every task here is
  # a container, and a connect-native primary task keeps a non-nil `Kind` but
  # still has `Lifecycle == nil`, so it is correctly kept.
  defp image_from(%{"TaskGroups" => groups}) when is_list(groups) do
    groups
    |> Enum.flat_map(&Map.get(&1, "Tasks", []))
    |> Enum.filter(&(&1["Lifecycle"] == nil))
    |> pick_task()
    |> case do
      nil -> nil
      task -> get_in(task, ["Config", "image"])
    end
  end

  defp image_from(_detail), do: nil

  defp pick_task([]), do: nil
  defp pick_task([first | _] = tasks), do: Enum.find(tasks, first, &(&1["Leader"] == true))

  # `Periodic.Specs` if non-empty, else `Periodic.Spec` (Decision 5) — the
  # two are mutually exclusive in every jobspec Nomad accepts (validation
  # rejects a job with both set, or with neither), so reading both covers the
  # legacy `cron` block and the modern `crons` block with no multi-cron
  # display rule needed. `Enum.join/2` only matters if a multi-cron jobspec
  # ever appears; none does today.
  defp cron_from(%{"Periodic" => %{"Specs" => specs}}) when is_list(specs) and specs != [] do
    Enum.join(specs, ", ")
  end

  defp cron_from(%{"Periodic" => %{"Spec" => spec}}) when is_binary(spec) and spec != "" do
    spec
  end

  defp cron_from(_detail), do: nil
end
