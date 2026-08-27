defmodule NucleusWeb.Nomad.JobFormatTest do
  use ExUnit.Case, async: true

  alias Nucleus.NomadJobs.Job
  alias NucleusWeb.Nomad.JobFormat

  doctest JobFormat

  defp job(overrides) do
    defaults = %{
      name: "acme-api",
      status: "running",
      namespace: "local",
      periodic?: false,
      version: 42,
      image: "acme/api:v1.4.0",
      cron: nil,
      detail_error: nil
    }

    struct!(Job, Map.merge(defaults, Map.new(overrides)))
  end

  describe "status_class/1 — APP-A02" do
    @tag action: "APP-A02"
    test "running, pending, and dead map to pairwise-distinct classes" do
      classes = %{
        running: JobFormat.status_class(job(status: "running")),
        pending: JobFormat.status_class(job(status: "pending")),
        dead: JobFormat.status_class(job(status: "dead"))
      }

      assert classes.running == "badge badge-success"
      assert classes.pending == "badge badge-warning"
      assert classes.dead == "badge badge-error"

      assert classes |> Map.values() |> Enum.uniq() |> length() == 3
    end

    @tag action: "APP-A02"
    test "an unrecognized status degrades to a neutral class, not a crash" do
      assert JobFormat.status_class(job(status: "garden_gnome")) == "badge badge-neutral"
    end
  end

  describe "status_text/1" do
    test "passes the raw status text through, unaffected by detail_error" do
      assert JobFormat.status_text(job(status: "running")) == "running"

      assert JobFormat.status_text(job(status: "running", detail_error: :unavailable)) ==
               "running"
    end
  end

  describe "version_text/1 — APP-A03" do
    @tag action: "APP-A03"
    test "renders the scheduler revision as explicit text" do
      assert JobFormat.version_text(job(version: 42)) == "42"
      assert JobFormat.version_text(job(version: 0)) == "0"
    end

    @tag action: "APP-A03"
    test "'not available' when version is nil, independent of the image" do
      assert JobFormat.version_text(job(version: nil, image: "acme/api:v1.4.0")) ==
               "not available"

      assert JobFormat.version_text(job(version: nil, image: nil)) == "not available"
    end

    @tag action: "APP-A03"
    test "'not available' for a detail_error-degraded job" do
      assert JobFormat.version_text(job(version: nil, detail_error: :unavailable)) ==
               "not available"
    end
  end

  describe "image_text/1 — APP-A03" do
    @tag action: "APP-A03"
    test "renders name:tag as a single string" do
      assert JobFormat.image_text(job(image: "acme/api:v1.4.0")) == "acme/api:v1.4.0"
    end

    @tag action: "APP-A03"
    test "an unresolved template-variable reference renders as-is, unresolved" do
      assert JobFormat.image_text(job(image: "${meta.connect.gateway_image}")) ==
               "${meta.connect.gateway_image}"
    end

    @tag action: "APP-A03"
    test "'not available' when no image is configured, a genuine absence" do
      assert JobFormat.image_text(job(image: nil, detail_error: nil)) == "not available"
    end

    @tag action: "APP-A03"
    test "'not available' for a detail_error-degraded job" do
      assert JobFormat.image_text(job(image: nil, detail_error: :unavailable)) ==
               "not available"
    end
  end

  describe "schedule_text/1 — APP-A04, APP-A05" do
    @tag action: "APP-A04"
    test "renders the cron spec for a periodic job" do
      assert JobFormat.schedule_text(job(periodic?: true, cron: "0 3 * * *")) == "0 3 * * *"
    end

    @tag action: "APP-A05"
    test "renders an explicit 'No schedule' for a non-periodic job" do
      assert JobFormat.schedule_text(job(periodic?: false, cron: nil)) == "No schedule"
    end

    test "'not available' for a detail_error-degraded periodic job — cron is unknown, not absent" do
      assert JobFormat.schedule_text(job(periodic?: true, cron: nil, detail_error: :unavailable)) ==
               "not available"
    end

    test "a detail_error-degraded non-periodic job still reads 'not available'" do
      # periodic? comes from the list stub, not the detail call, but every
      # formatter here checks detail_error first — consistent with version
      # and image reading "not available" together, not just cron.
      assert JobFormat.schedule_text(job(periodic?: false, cron: nil, detail_error: :unavailable)) ==
               "not available"
    end
  end
end
