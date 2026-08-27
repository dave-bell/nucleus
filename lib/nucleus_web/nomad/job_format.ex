defmodule NucleusWeb.Nomad.JobFormat do
  @moduledoc """
  Shared, pure display formatting for `Nucleus.NomadJobs.Job` (`APP-A02`,
  `APP-A03`, `APP-A04`, `APP-A05`).

  `NucleusWeb.ApplicationsLive`'s row template and DEX-S5 (#77)'s deployment
  status panel both format the same struct — status, version, image, cron —
  so this is a real shared module, not two independently maintained private
  helpers that can silently drift apart, per the precedent
  `NucleusWeb.M2MClientsLive.Format` set for `created_date/1`.

  ## `detail_error` degrades version, image, and cron together

  `Job.t()`'s `version`, `image`, and `cron` all come from the same per-job
  detail call (`docs/adr/0022`, Decision 6) — a non-nil `detail_error` means
  all three are unknown, never just one. Every formatter here checks
  `detail_error` first and returns the same `"not available"` text for it,
  rather than three functions independently re-deriving that a failed
  detail fetch means "unknown" for their own field. `periodic?` is exempt:
  it comes from the list stub, not the detail call, so it stays accurate
  even on a degraded row — but the cron *text* itself is one of the three
  detail-only fields, so `schedule_text/1` still reads "not available" for
  a degraded periodic job rather than rendering a cron spec it doesn't have.

  ## `image: nil` is a genuine absence, not a fetch failure

  A job with no task where `Lifecycle == nil` (`docs/adr/0022`, Decision 3)
  has `image: nil` with `detail_error: nil` — the detail call succeeded and
  said "no image here." `image_text/1` renders the same `"not available"`
  text for this case as for a `detail_error`-degraded row, since neither
  case should render blank (`APP-A03`'s edge-case matrix), but the two are
  different conditions collapsing to the same user-facing text, not the
  same condition.
  """

  alias Nucleus.NomadJobs.Job

  @not_available "not available"

  @doc """
  The daisyUI badge classes for a job's status (`APP-A02`).

  `"running"`, `"pending"`, and `"dead"` are Nomad's three documented
  values and get pairwise-distinct classes; anything else — the enum is
  closed today, but defensive handling costs nothing — degrades to a
  neutral class rather than crashing.

      iex> NucleusWeb.Nomad.JobFormat.status_class(%Nucleus.NomadJobs.Job{name: "n", status: "running", namespace: "ns", periodic?: false})
      "badge badge-success"

      iex> NucleusWeb.Nomad.JobFormat.status_class(%Nucleus.NomadJobs.Job{name: "n", status: "pending", namespace: "ns", periodic?: false})
      "badge badge-warning"

      iex> NucleusWeb.Nomad.JobFormat.status_class(%Nucleus.NomadJobs.Job{name: "n", status: "dead", namespace: "ns", periodic?: false})
      "badge badge-error"

      iex> NucleusWeb.Nomad.JobFormat.status_class(%Nucleus.NomadJobs.Job{name: "n", status: "unknown", namespace: "ns", periodic?: false})
      "badge badge-neutral"
  """
  @spec status_class(Job.t()) :: String.t()
  def status_class(%Job{status: "running"}), do: "badge badge-success"
  def status_class(%Job{status: "pending"}), do: "badge badge-warning"
  def status_class(%Job{status: "dead"}), do: "badge badge-error"
  def status_class(%Job{}), do: "badge badge-neutral"

  @doc """
  The status text itself — `APP-A02` requires colour "in addition to", never
  instead of, the status text, so this is a passthrough kept here for
  DEX-S5 (#77)'s call site to use rather than reaching into `Job.status`
  directly.

      iex> NucleusWeb.Nomad.JobFormat.status_text(%Nucleus.NomadJobs.Job{name: "n", status: "running", namespace: "ns", periodic?: false})
      "running"
  """
  @spec status_text(Job.t()) :: String.t()
  def status_text(%Job{status: status}), do: status

  @doc """
  The job's Nomad scheduler revision (`APP-A03`) — a revision counter, not a
  release identifier (`docs/adr/0022`, Decision 1).

      iex> NucleusWeb.Nomad.JobFormat.version_text(%Nucleus.NomadJobs.Job{name: "n", status: "running", namespace: "ns", periodic?: false, version: 42})
      "42"

      iex> NucleusWeb.Nomad.JobFormat.version_text(%Nucleus.NomadJobs.Job{name: "n", status: "running", namespace: "ns", periodic?: false, version: nil, detail_error: :unavailable})
      "not available"
  """
  @spec version_text(Job.t()) :: String.t()
  def version_text(%Job{detail_error: kind}) when not is_nil(kind), do: @not_available
  def version_text(%Job{version: nil}), do: @not_available
  def version_text(%Job{version: version}), do: Integer.to_string(version)

  @doc """
  The container image name:tag (`APP-A03`) — rendered as-is, including an
  unresolved template variable reference (e.g. `${meta.connect.gateway_image}`)
  surviving in a stored job spec. No resolution attempt happens at this
  layer; `Nucleus.NomadJobs.Job.from_api/3` already refused to resolve it.

      iex> NucleusWeb.Nomad.JobFormat.image_text(%Nucleus.NomadJobs.Job{name: "n", status: "running", namespace: "ns", periodic?: false, image: "nginx:1.25"})
      "nginx:1.25"

      iex> NucleusWeb.Nomad.JobFormat.image_text(%Nucleus.NomadJobs.Job{name: "n", status: "running", namespace: "ns", periodic?: false, image: nil})
      "not available"
  """
  @spec image_text(Job.t()) :: String.t()
  def image_text(%Job{detail_error: kind}) when not is_nil(kind), do: @not_available
  def image_text(%Job{image: nil}), do: @not_available
  def image_text(%Job{image: image}), do: image

  @doc """
  The schedule cell — a periodic job's cron spec (`APP-A04`), or an
  explicit, never-blank "No schedule" for a non-periodic job (`APP-A05`).

  `periodic?` comes from the list stub, not the detail call, so it is
  accurate even when `detail_error` is set — but the cron text itself is
  one of the three detail-only fields, so a `detail_error`-degraded
  periodic job still reads "not available" here, not its (unknown) cron
  spec.

      iex> NucleusWeb.Nomad.JobFormat.schedule_text(%Nucleus.NomadJobs.Job{name: "n", status: "running", namespace: "ns", periodic?: true, cron: "0 0 * * * *"})
      "0 0 * * * *"

      iex> NucleusWeb.Nomad.JobFormat.schedule_text(%Nucleus.NomadJobs.Job{name: "n", status: "running", namespace: "ns", periodic?: false})
      "No schedule"

      iex> NucleusWeb.Nomad.JobFormat.schedule_text(%Nucleus.NomadJobs.Job{name: "n", status: "running", namespace: "ns", periodic?: true, cron: nil, detail_error: :unavailable})
      "not available"
  """
  @spec schedule_text(Job.t()) :: String.t()
  def schedule_text(%Job{detail_error: kind}) when not is_nil(kind), do: @not_available
  def schedule_text(%Job{periodic?: false}), do: "No schedule"
  def schedule_text(%Job{periodic?: true, cron: nil}), do: @not_available
  def schedule_text(%Job{periodic?: true, cron: cron}), do: cron
end
