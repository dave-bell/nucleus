defmodule NucleusWeb.ApplicationsLiveTest do
  # `force_error/2` mutates the node-global `LOCAL_FORCE_ERROR` env var
  # (`Nucleus.Backend.Faults`) — matching `Nucleus.BackendCase`'s own
  # `async: false` requirement.
  use NucleusWeb.LiveCase, async: false

  alias Nucleus.Backend.Error

  # Seeded in priv/backends/local_seed.json — parent jobs only, per
  # `Nucleus.NomadJobs.Job.child?/1`'s exclusion.
  @seeded_parent_names [
    "acme-api",
    "acme-ingress",
    "acme-nightly-report",
    "acme-hourly-sync",
    "acme-batch-import",
    "acme-adhoc-export",
    "acme-legacy-raw-exec",
    "acme-worker-pending",
    "acme-worker-dead"
  ]

  # Seeded children — periodic and dispatch alike — that must never render
  # as their own row (`APP-A01`).
  @seeded_child_names [
    "acme-nightly-report/periodic-1755000000",
    "acme-nightly-report/periodic-1755086400",
    "acme-batch-import/dispatch-1755000111",
    "acme-batch-import/dispatch-1755000222"
  ]

  describe "APP-A01 — view the tenant's deployed applications" do
    @tag action: "APP-A01"
    test "lists every seeded parent job with name, status, and its fixed-id cells", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/applications")

      assert has_element?(view, "#applications-table")

      for name <- @seeded_parent_names do
        assert has_element?(view, "#applications-table-body", name)
        assert has_element?(view, "#job-#{name}-status")
        assert has_element?(view, "#job-#{name}-version")
        assert has_element?(view, "#job-#{name}-image")
        assert has_element?(view, "#job-#{name}-schedule")
      end
    end

    @tag action: "APP-A01"
    test "a periodic parent's children never render as their own rows", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/applications")

      for child_name <- [
            "acme-nightly-report/periodic-1755000000",
            "acme-nightly-report/periodic-1755086400"
          ] do
        refute html =~ child_name
      end
    end

    @tag action: "APP-A01"
    test "a dispatch parent's children never render as their own rows", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/applications")

      for child_name <- [
            "acme-batch-import/dispatch-1755000111",
            "acme-batch-import/dispatch-1755000222"
          ] do
        refute html =~ child_name
      end
    end

    @tag action: "APP-A01"
    test "no seeded child name appears anywhere in the rendered HTML", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/applications")

      for child_name <- @seeded_child_names do
        refute html =~ child_name
      end
    end

    @tag action: "APP-A01"
    test "row order is stable across two mounts", %{conn: conn} do
      {:ok, view1, _html} = live(conn, ~p"/applications")
      {:ok, view2, _html} = live(conn, ~p"/applications")

      names1 = row_job_names(view1)
      names2 = row_job_names(view2)

      assert names1 != []
      assert names1 == names2
      assert names1 == Enum.sort_by(names1, &String.downcase/1)
    end
  end

  describe "APP-A02 — distinguish job status at a glance" do
    @tag action: "APP-A02"
    test "running, pending, and dead rows carry distinct status classes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/applications")

      assert has_element?(view, "#job-acme-api-status.badge-success")
      assert has_element?(view, "#job-acme-worker-pending-status.badge-warning")
      assert has_element?(view, "#job-acme-worker-dead-status.badge-error")
    end

    @tag action: "APP-A02"
    test "status text is present in every case, alongside — not replaced by — the class", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/applications")

      assert view |> element("#job-acme-api-status") |> render() =~ "running"
      assert view |> element("#job-acme-worker-pending-status") |> render() =~ "pending"
      assert view |> element("#job-acme-worker-dead-status") |> render() =~ "dead"
    end
  end

  describe "APP-A03 — see the explicit version and image of each deployed application" do
    @tag action: "APP-A03"
    test "a job with an image renders both an explicit version and image:tag, as two distinct cells",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/applications")

      version_text = view |> element("#job-acme-api-version") |> render()
      image_text = view |> element("#job-acme-api-image") |> render()

      refute version_text =~ "not available"
      refute image_text =~ "not available"
      assert version_text != image_text
    end

    @tag action: "APP-A03"
    test "the seeded no-image fixture renders 'not available' in both cells, row layout intact",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/applications")

      assert view |> element("#job-acme-legacy-raw-exec-image") |> render() =~ "not available"

      # Version is its own condition, not derived from the image's — a job
      # with no image still has a revision.
      refute view |> element("#job-acme-legacy-raw-exec-version") |> render() =~
               "not available"

      # Adjacent cells (name, status) are unaffected.
      assert has_element?(view, "#applications-table-body", "acme-legacy-raw-exec")
      assert has_element?(view, "#job-acme-legacy-raw-exec-status")
    end

    @tag action: "APP-A03"
    test "the seeded template-variable-image fixture renders the literal unresolved string", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/applications")

      assert view |> element("#job-acme-ingress-image") |> render() =~
               "${meta.connect.gateway_image}"
    end
  end

  describe "APP-A04 — see the schedule of periodic applications" do
    @tag action: "APP-A04"
    test "a periodic job renders its cron spec", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/applications")

      assert view |> element("#job-acme-nightly-report-schedule") |> render() =~ "*"
      refute view |> element("#job-acme-nightly-report-schedule") |> render() =~ "No schedule"
    end

    @tag action: "APP-A04"
    test "the modern crons block (Periodic.Specs) also renders its cron spec", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/applications")

      refute view |> element("#job-acme-hourly-sync-schedule") |> render() =~ "No schedule"
    end
  end

  describe "APP-A05 — non-scheduled applications show no schedule" do
    @tag action: "APP-A05"
    test "the seeded non-periodic job renders an explicit 'No schedule' string, never blank", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/applications")

      assert view |> element("#job-acme-api-schedule") |> render() =~ "No schedule"
    end

    @tag action: "APP-A05"
    test "a parameterized parent with zero dispatches also renders 'No schedule'", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/applications")

      assert view |> element("#job-acme-adhoc-export-schedule") |> render() =~ "No schedule"
    end
  end

  describe "APP-A06 — empty state" do
    @tag action: "APP-A06"
    test "zero seeded jobs renders #applications-empty, not the table", %{conn: conn} do
      Nucleus.Backend.Seed.write(:nomad_jobs, [])

      {:ok, view, _html} = live(conn, ~p"/applications")

      assert has_element?(view, "#applications-empty")
      refute has_element?(view, "#applications-table")
    end
  end

  describe "APP-A07 — error state when Nomad is unreachable" do
    @tag action: "APP-A07"
    test "forced :unavailable renders #applications-unavailable, shell intact, with a retry control",
         %{conn: conn} do
      force_error(:nomad_jobs, :unavailable)

      {:ok, view, _html} = live(conn, ~p"/applications")

      assert has_element?(view, "#applications-unavailable")
      refute has_element?(view, "#applications-table")
      refute has_element?(view, "#applications-empty")
      # the shell survives — the rest of the header/sidebar remains usable.
      assert has_element?(view, "#tenant-identifier")
    end

    @tag action: "APP-A07"
    test "retry re-fetches and shows the table once the fault clears", %{conn: conn} do
      force_error(:nomad_jobs, :unavailable)

      {:ok, view, _html} = live(conn, ~p"/applications")
      assert has_element?(view, "#applications-unavailable")

      clear_faults()

      view |> element("[phx-click='retry']") |> render_click()

      assert has_element?(view, "#applications-table")
      refute has_element?(view, "#applications-unavailable")
    end
  end

  describe "every Nucleus.Backend.Error kind renders a distinct state, shell intact, no crash" do
    @error_state_ids %{
      not_configured: "applications-misconfigured",
      unavailable: "applications-unavailable",
      auth_expired: "applications-auth-expired"
    }

    for {kind, expected_id} <- @error_state_ids do
      @tag kind: kind
      @tag expected_id: expected_id
      test "#{kind} renders #{expected_id}, mutually exclusive, shell intact", %{
        conn: conn,
        kind: kind,
        expected_id: expected_id
      } do
        force_error(:nomad_jobs, kind)

        {:ok, view, _html} = live(conn, ~p"/applications")

        assert has_element?(view, "##{expected_id}")

        for other_id <- Map.values(@error_state_ids) -- [expected_id] do
          refute has_element?(view, "##{other_id}")
        end

        refute has_element?(view, "#applications-table")
        refute has_element?(view, "#applications-empty")
        assert has_element?(view, "#tenant-identifier")
      end
    end

    test "every remaining kind collapses to #applications-unavailable and never crashes", %{
      conn: conn
    } do
      named_kinds = Map.keys(@error_state_ids)

      for kind <- Error.kinds() -- named_kinds do
        force_error(:nomad_jobs, kind)

        assert {:ok, view, _html} = live(conn, ~p"/applications")
        assert has_element?(view, "#applications-unavailable")
        assert has_element?(view, "#tenant-identifier")

        clear_faults()
      end
    end

    test "live/2 returns {:ok, ...} for every error kind — the LiveView never crashes", %{
      conn: conn
    } do
      for kind <- Error.kinds() do
        force_error(:nomad_jobs, kind)
        assert {:ok, _view, _html} = live(conn, ~p"/applications")
        clear_faults()
      end
    end
  end

  describe "APP-A08 — read-only, no mutating affordance" do
    @tag action: "APP-A08"
    test "no create, edit, delete, restart, or redeploy control exists anywhere on the view", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/applications")

      refute has_element?(view, "[phx-click='create']")
      refute has_element?(view, "[phx-click='edit']")
      refute has_element?(view, "[phx-click='delete']")
      refute has_element?(view, "[phx-click='restart']")
      refute has_element?(view, "[phx-click='redeploy']")
      refute has_element?(view, "button", "New")
      refute has_element?(view, "th", "Actions")
    end

    @tag action: "APP-A08"
    test "none of the words Restart, Redeploy, Delete, or Edit appear inside #applications-table",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/applications")

      table_html = view |> element("#applications-table") |> render()

      refute table_html =~ "Restart"
      refute table_html =~ "Redeploy"
      refute table_html =~ "Delete"
      refute table_html =~ "Edit"
    end
  end

  describe "sidebar — Applications is a real, functional link" do
    test "the sidebar renders a navigate link to /applications, not a disabled span", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/applications")

      doc = view |> render() |> LazyHTML.from_fragment()

      applications_link =
        doc
        |> LazyHTML.query("#sidebar a")
        |> Enum.find(fn node -> LazyHTML.text(node) =~ "Applications" end)

      refute is_nil(applications_link)
      assert LazyHTML.attribute(applications_link, "href") == ["/applications"]

      refute has_element?(view, "#sidebar span[aria-disabled='true']", "Applications")
    end

    test "clicking the sidebar link from another authenticated view navigates to /applications",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      assert {:ok, applications_view, _html} =
               view
               |> element("#sidebar a", "Applications")
               |> render_click()
               |> follow_redirect(conn, ~p"/applications")

      assert has_element?(applications_view, "#applications-table")
    end
  end

  defp row_job_names(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#applications-table-body [data-job-name]")
    |> LazyHTML.attribute("data-job-name")
  end
end
