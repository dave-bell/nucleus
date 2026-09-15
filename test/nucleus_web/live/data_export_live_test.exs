defmodule NucleusWeb.DataExportLiveTest do
  # `force_error/2`/`Nucleus.Backend.Seed.write/2` mutate node-global state
  # (`Nucleus.Backend.Faults`, `Nucleus.Backend.Seed`) — matching
  # `Nucleus.BackendCase`'s own `async: false` requirement.
  use NucleusWeb.LiveCase, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Seed
  alias Nucleus.NomadVars

  # Seeded in priv/backends/local_seed.json under TENANT_NAMESPACE = "local".
  @seeded_path "nomad/jobs/local-data_export"
  @seeded_keys ["description", "env_names", "destination_bucket"]

  defmodule NomadVarsWriteSpy do
    @moduledoc """
    Delegates `read/0` and `health_check/0` to the real
    `Nucleus.NomadVars.Store.Local`, and counts `write/2` calls via
    `Nucleus.Backend.Seed` — for proving *no* adapter call happened (cancel,
    and the server-side re-check's mismatched-key rejection). `LOCAL_FORCE_ERROR`
    (`Nucleus.Backend.Faults`) cannot prove a negative like this — forcing an
    error still lets a call through, it just makes that call fail — so this
    swaps the boundary's implementation instead, the same technique
    `NucleusWeb.SecretsLiveTest.FailingSecretsStore` uses, per `M2M-S1`'s
    established reasoning against the node-global fault for a targeted
    assertion.
    """
    @behaviour Nucleus.NomadVars.Store

    @counter :nomad_vars_write_spy_calls

    @impl Nucleus.NomadVars.Store
    def read, do: Nucleus.NomadVars.Store.Local.read()

    @impl Nucleus.NomadVars.Store
    def write(items, expected_modify_index) do
      Seed.update(@counter, fn count -> (count || 0) + 1 end)
      Nucleus.NomadVars.Store.Local.write(items, expected_modify_index)
    end

    @impl Nucleus.NomadVars.Store
    def health_check, do: Nucleus.NomadVars.Store.Local.health_check()

    @spec write_calls() :: non_neg_integer()
    def write_calls, do: Seed.read(@counter) || 0
  end

  defp use_write_spy do
    original = Application.get_env(:nucleus, :backends, [])
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)

    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(original, :nomad_vars, NomadVarsWriteSpy)
    )
  end

  defmodule FailingTenantApi do
    @moduledoc """
    A `Nucleus.TenantApi` implementation whose `list_environments/1` always
    fails — the same swapped-module technique
    `NucleusWeb.EnvironmentsLiveTest.FailingTenantApi` uses, per `M2M-S1`'s
    established reasoning against the node-global `LOCAL_FORCE_ERROR` fault
    for a targeted, single-boundary assertion (this LiveView's own
    `EnvironmentsHook` calls the same `:tenant_api` boundary on every mount,
    so a node-global fault would also be caught there).
    """
    @behaviour Nucleus.TenantApi

    @impl Nucleus.TenantApi
    def list_environments(_token),
      do: {:error, Error.new(:unavailable, :tenant_api, "forced for test", %{})}

    @impl Nucleus.TenantApi
    def health_check, do: raise("should not be called")
  end

  defp use_failing_tenant_api do
    original = Application.get_env(:nucleus, :backends, [])
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)

    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(original, :tenant_api, FailingTenantApi)
    )
  end

  defmodule NomadJobsAlwaysUnavailable do
    @moduledoc """
    Always errs, ignoring `LOCAL_FORCE_ERROR` entirely — proving `DEX-A02`'s
    independence claim without `force_error/2`, which is node-global
    (`Nucleus.Backend.Faults`) and would fault `:nomad_vars` too, since
    `Nucleus.NomadVars.Store.Local` checks the very same env var. Swapping
    the `:nomad_jobs` backend instead keeps `:nomad_vars` genuinely
    unaffected, the same technique `NomadVarsWriteSpy` above uses for the
    opposite direction.
    """
    @behaviour Nucleus.NomadJobs

    alias Nucleus.Backend.Error

    @impl Nucleus.NomadJobs
    def list_jobs(_namespace) do
      {:error, Error.new(:unavailable, Nucleus.NomadJobs.boundary(), "forced for test")}
    end

    @impl Nucleus.NomadJobs
    def health_check, do: :ok
  end

  defmodule NomadVarsAlwaysUnavailable do
    @moduledoc """
    Always errs on `read/0`, for the opposite direction from
    `NomadJobsAlwaysUnavailable` — proving a `:nomad_vars` outage does not
    blank the deployment status panel, without reaching for
    `force_error/2` (which would fault `:nomad_jobs` too).
    """
    @behaviour Nucleus.NomadVars.Store

    alias Nucleus.Backend.Error

    @impl Nucleus.NomadVars.Store
    def read, do: {:error, Error.new(:unavailable, :nomad_vars, "forced for test")}

    @impl Nucleus.NomadVars.Store
    def write(_items, _expected_modify_index) do
      {:error, Error.new(:unavailable, :nomad_vars, "forced for test")}
    end

    @impl Nucleus.NomadVars.Store
    def health_check, do: :ok
  end

  defp use_nomad_jobs_double(module) do
    original = Application.get_env(:nucleus, :backends, [])
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)

    Application.put_env(:nucleus, :backends, Keyword.put(original, :nomad_jobs, module))
  end

  defp use_nomad_vars_double(module) do
    original = Application.get_env(:nucleus, :backends, [])
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)

    Application.put_env(:nucleus, :backends, Keyword.put(original, :nomad_vars, module))
  end

  describe "DEX-A01 — detect whether Data Export is enabled" do
    @tag action: "DEX-A01"
    test "a tenant without the variable path sees a clear not-enabled message, no table", %{
      conn: conn
    } do
      Seed.write(:nomad_vars, false)

      {:ok, view, _html} = live_data_export(conn)

      assert has_element?(view, "#data-export-not-enabled")
      refute has_element?(view, "#data-export-table")
      refute has_element?(view, "#data-export-empty")
      # the shell survives even when the feature itself is off.
      assert has_element?(view, "#tenant-identifier")
    end

    @tag action: "DEX-A01"
    test "no retry affordance is offered — this is not a transient failure", %{conn: conn} do
      Seed.write(:nomad_vars, false)

      {:ok, view, _html} = live_data_export(conn)

      refute has_element?(view, "#data-export-not-enabled [phx-click='retry']")
    end

    @tag action: "DEX-A01"
    test "the seeded enabled fixture does not show the not-enabled message", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      refute has_element?(view, "#data-export-not-enabled")
    end

    @tag action: "DEX-A01"
    test "the disconnected (static, pre-websocket) render already reflects not-enabled, not a blank shell",
         %{conn: conn} do
      Seed.write(:nomad_vars, false)

      html = conn |> get(~p"/data-export") |> html_response(200)

      assert html =~ "data-export-not-enabled"
      refute html =~ "data-export-table"
    end
  end

  describe "DEX-A03 — view current Data Export configuration" do
    @tag action: "DEX-A03"
    test "every seeded key/value renders unmasked, plus one shared modified-at", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      assert has_element?(view, "#data-export-table")

      for key <- @seeded_keys do
        assert has_element?(view, "#var-#{key}-value")
      end

      assert view |> element("#var-description-value") |> render() =~
               "Nightly export of tenant usage metrics"

      assert view |> element("#var-env_names-value") |> render() =~ "prod,staging"

      # values are unmasked — no bullet/dot masking character present.
      refute view |> element("#var-env_names-value") |> render() =~ "•"

      assert has_element?(view, "#data-export-modified-at")
    end

    @tag action: "DEX-A03"
    test "the modified-at value is shared, not rendered once per row", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      # exactly one shared element, not one per seeded key.
      doc = view |> render() |> LazyHTML.from_fragment()
      assert doc |> LazyHTML.query("#data-export-modified-at") |> Enum.count() == 1

      for key <- @seeded_keys do
        refute has_element?(view, "#var-#{key}-modified")
      end
    end

    @tag action: "DEX-A03"
    test "rows render in stable, case-insensitive name order across repeated loads", %{
      conn: conn
    } do
      {:ok, view1, _html} = live_data_export(conn)
      {:ok, view2, _html} = live_data_export(conn)

      names1 = row_keys(view1)
      names2 = row_keys(view2)

      assert names1 != []
      assert names1 == names2
      assert names1 == Enum.sort_by(names1, &String.downcase/1)
    end

    @tag action: "DEX-A03"
    test "the disconnected (static, pre-websocket) render already shows the real table, not a blank shell",
         %{conn: conn} do
      html = conn |> get(~p"/data-export") |> html_response(200)

      assert html =~ "data-export-table"
      assert html =~ "Nightly export of tenant usage metrics"
      refute html =~ "data-export-not-enabled"
      refute html =~ "data-export-unavailable"
    end
  end

  describe "DEX-A12 — empty configuration state" do
    @tag action: "DEX-A12"
    test "an enabled-but-empty fixture renders #data-export-empty, no table", %{conn: conn} do
      Seed.write(:nomad_vars, %{
        "path" => @seeded_path,
        "items" => %{},
        "modify_index" => 1,
        "modified_at" => nil
      })

      {:ok, view, _html} = live_data_export(conn)

      assert has_element?(view, "#data-export-empty")
      refute has_element?(view, "#data-export-table")
      refute has_element?(view, "#data-export-not-enabled")
    end
  end

  describe "DEX-A13 — error loading configuration" do
    @tag action: "DEX-A13"
    test "forced :unavailable renders #data-export-unavailable, shell intact, with retry", %{
      conn: conn
    } do
      force_error(:nomad_vars, :unavailable)

      {:ok, view, _html} = live_data_export(conn)

      assert has_element?(view, "#data-export-unavailable")
      refute has_element?(view, "#data-export-table")
      refute has_element?(view, "#data-export-empty")
      assert has_element?(view, "#tenant-identifier")
    end

    @tag action: "DEX-A13"
    test "retry re-fetches and shows the table once the fault clears", %{conn: conn} do
      force_error(:nomad_vars, :unavailable)

      {:ok, view, _html} = live_data_export(conn)
      assert has_element?(view, "#data-export-unavailable")

      clear_faults()

      view |> element("[phx-click='retry']") |> render_click()

      assert has_element?(view, "#data-export-table")
      refute has_element?(view, "#data-export-unavailable")
    end
  end

  describe "every Nucleus.Backend.Error kind renders a distinct state, shell intact, no crash" do
    @error_state_ids %{
      not_found: "data-export-not-enabled",
      not_configured: "data-export-misconfigured",
      unavailable: "data-export-unavailable",
      auth_expired: "data-export-auth-expired"
    }

    for {kind, expected_id} <- @error_state_ids do
      @tag kind: kind
      @tag expected_id: expected_id
      test "#{kind} renders #{expected_id}, mutually exclusive, shell intact", %{
        conn: conn,
        kind: kind,
        expected_id: expected_id
      } do
        force_error(:nomad_vars, kind)

        {:ok, view, _html} = live_data_export(conn)

        assert has_element?(view, "##{expected_id}")

        for other_id <- Map.values(@error_state_ids) -- [expected_id] do
          refute has_element?(view, "##{other_id}")
        end

        refute has_element?(view, "#data-export-table")
        refute has_element?(view, "#data-export-empty")
        assert has_element?(view, "#tenant-identifier")
      end
    end

    test "every remaining kind (including :conflict) collapses to #data-export-unavailable and never crashes",
         %{conn: conn} do
      named_kinds = Map.keys(@error_state_ids)

      for kind <- Error.kinds() -- named_kinds do
        force_error(:nomad_vars, kind)

        assert {:ok, view, _html} = live_data_export(conn)
        assert has_element?(view, "#data-export-unavailable")
        assert has_element?(view, "#tenant-identifier")

        clear_faults()
      end
    end

    test "live/2 returns {:ok, ...} for every error kind — the LiveView never crashes", %{
      conn: conn
    } do
      for kind <- Error.kinds() do
        force_error(:nomad_vars, kind)
        assert {:ok, _view, _html} = live_data_export(conn)
        clear_faults()
      end
    end
  end

  describe "DEX-A14 — no create or delete of configuration keys" do
    @tag action: "DEX-A14"
    test "no create, edit, or delete control exists anywhere on the view", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      refute has_element?(view, "[phx-click='create']")
      refute has_element?(view, "[phx-click='new_variable']")
      refute has_element?(view, "[phx-click='delete']")
      refute has_element?(view, "[phx-click='remove']")
      refute has_element?(view, "button", "New")
      refute has_element?(view, "th", "Actions")
    end

    @tag action: "DEX-A14"
    test "none of the words Add, New, Delete, or Remove appear inside #data-export-table", %{
      conn: conn
    } do
      {:ok, view, _html} = live_data_export(conn)

      table_html = view |> element("#data-export-table") |> render()

      refute table_html =~ "Add"
      refute table_html =~ "New"
      refute table_html =~ "Delete"
      refute table_html =~ "Remove"
    end
  end

  describe "DEX-A02 — view Data Export deployment status" do
    @tag action: "DEX-A02"
    test "shows the seeded Data Export job's status, version, image, and cron schedule", %{
      conn: conn
    } do
      {:ok, view, _html} = live_data_export(conn)
      render_async(view)

      assert has_element?(view, "#data-export-job-status")
      refute has_element?(view, "#data-export-job-unavailable")

      panel = view |> element("#data-export-job-status") |> render()
      assert panel =~ "running"
      assert panel =~ "3"
      assert panel =~ "registry.example.com/acme/data-export:sha-ccc3333"
      assert panel =~ "0 3 * * *"
    end

    @tag action: "DEX-A02"
    test "a non-periodic job renders the shared formatter's no-schedule text", %{conn: conn} do
      Seed.write(:nomad_jobs, [
        %{
          "stub" => %{
            "ID" => "local-data_export",
            "ParentID" => nil,
            "Name" => "local-data_export",
            "Status" => "running",
            "Periodic" => false
          },
          "detail" => %{
            "Version" => 1,
            "TaskGroups" => [
              %{
                "Tasks" => [
                  %{
                    "Name" => "export",
                    "Lifecycle" => nil,
                    "Leader" => true,
                    "Config" => %{"image" => "registry.example.com/acme/data-export:sha-none"}
                  }
                ]
              }
            ]
          }
        }
      ])

      {:ok, view, _html} = live_data_export(conn)
      render_async(view)

      panel = view |> element("#data-export-job-status") |> render()
      assert panel =~ "No schedule"
    end

    @tag action: "DEX-A02"
    test "the job-absent state renders #data-export-job-unavailable, distinct from #data-export-unavailable",
         %{conn: conn} do
      Seed.write(:nomad_jobs, [])

      {:ok, view, _html} = live_data_export(conn)
      render_async(view)

      assert has_element?(view, "#data-export-job-unavailable")
      refute has_element?(view, "#data-export-unavailable")
      # the configuration table's own boundary is untouched by the job's absence.
      assert has_element?(view, "#data-export-table")
    end

    @tag action: "DEX-A02"
    test "a NomadJobs.list/1 error also renders #data-export-job-unavailable, collapsed with job-absent",
         %{conn: conn} do
      use_nomad_jobs_double(NomadJobsAlwaysUnavailable)

      {:ok, view, _html} = live_data_export(conn)
      render_async(view)

      assert has_element?(view, "#data-export-job-unavailable")
    end

    @tag action: "DEX-A02"
    test "a NomadJobs outage does not blank the configuration table", %{conn: conn} do
      use_nomad_jobs_double(NomadJobsAlwaysUnavailable)

      {:ok, view, _html} = live_data_export(conn)
      render_async(view)

      assert has_element?(view, "#data-export-table")
      assert has_element?(view, "#data-export-job-unavailable")
    end

    @tag action: "DEX-A02"
    test "a NomadVars outage does not blank the deployment status panel", %{conn: conn} do
      use_nomad_vars_double(NomadVarsAlwaysUnavailable)

      {:ok, view, _html} = live_data_export(conn)
      render_async(view)

      assert has_element?(view, "#data-export-unavailable")
      assert has_element?(view, "#data-export-job-status")
      refute has_element?(view, "#data-export-job-unavailable")
    end

    @tag action: "DEX-A02"
    test "retry_job_status re-fetches and clears the job panel's own failure state", %{
      conn: conn
    } do
      use_nomad_jobs_double(NomadJobsAlwaysUnavailable)

      {:ok, view, _html} = live_data_export(conn)
      render_async(view)
      assert has_element?(view, "#data-export-job-unavailable")

      use_nomad_jobs_double(Nucleus.NomadJobs.Local)

      view |> element("[phx-click='retry_job_status']") |> render_click()
      render_async(view)

      refute has_element?(view, "#data-export-job-unavailable")
      assert has_element?(view, "#data-export-job-status")
    end
  end

  describe "sidebar — Data Export is a real, functional link" do
    test "the sidebar renders a navigate link to /data-export, not a disabled span", %{
      conn: conn
    } do
      {:ok, view, _html} = live_data_export(conn)

      doc = view |> render() |> LazyHTML.from_fragment()

      data_export_link =
        doc
        |> LazyHTML.query("#sidebar a")
        |> Enum.find(fn node -> LazyHTML.text(node) =~ "Data Export" end)

      refute is_nil(data_export_link)
      assert LazyHTML.attribute(data_export_link, "href") == ["/data-export"]

      refute has_element?(view, "#sidebar span[aria-disabled='true']", "Data Export")
    end

    test "clicking the sidebar link from another authenticated view navigates to /data-export",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      assert {:ok, data_export_view, _html} =
               view
               |> element("#sidebar a", "Data Export")
               |> render_click()
               |> follow_redirect(conn, ~p"/data-export")

      assert has_element?(data_export_view, "#data-export-table")
    end
  end

  defp row_keys(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#data-export-table-body [data-var-key]")
    |> LazyHTML.attribute("data-var-key")
  end

  describe "DEX-A04 — edit the description" do
    @tag action: "DEX-A04"
    test "editing and saving description reflects the new value immediately", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view
      |> element("#var-description-edit")
      |> render_click()

      assert has_element?(view, "#data-export-edit-modal")
      assert has_element?(view, "#data-export-edit-form")
      assert view |> element("#data-export-edit-modal") |> render() =~ "description"

      view
      |> form("#data-export-edit-form", value: %{"value" => "Updated description."})
      |> render_submit()

      assert has_element?(view, "#var-description-value", "Updated description.")
      refute has_element?(view, "#data-export-edit-modal")
      assert has_element?(view, "#flash-info")
    end

    @tag action: "DEX-A04"
    test "the underlying store reflects the new value, and the audit event carries no value", %{
      conn: conn
    } do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-description-edit") |> render_click()

      view
      |> form("#data-export-edit-form", value: %{"value" => "Nightly export v2."})
      |> render_submit()

      assert {:ok, %{items: %{"description" => "Nightly export v2."}}} =
               NomadVars.fetch(%Nucleus.Scope{
                 tenant: "local",
                 user: %{email: "a@b.com", username: nil}
               })

      event =
        assert_audit_event(:nomad_var_updated,
          tenant: "local",
          details: %{path: @seeded_path, key: "description"}
        )

      refute Map.has_key?(event.details, :value)
    end
  end

  describe "DEX-A05 — edit an arbitrary configuration value" do
    @tag action: "DEX-A05"
    test "a non-description, non-env_names key edits and saves the same way", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-destination_bucket-edit") |> render_click()

      view
      |> form("#data-export-edit-form", value: %{"value" => "acme-analytics-v2"})
      |> render_submit()

      assert has_element?(view, "#var-destination_bucket-value", "acme-analytics-v2")
    end

    @tag action: "DEX-A05"
    test "cancel discards the edit; original value remains, no adapter call", %{conn: conn} do
      use_write_spy()
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-destination_bucket-edit") |> render_click()
      assert has_element?(view, "#data-export-edit-modal")

      view
      |> form("#data-export-edit-form", value: %{"value" => "not-going-to-be-saved"})
      |> render_change()

      view |> element("#data-export-cancel-edit") |> render_click()

      refute has_element?(view, "#data-export-edit-modal")
      assert has_element?(view, "#var-destination_bucket-value", "acme-analytics-prod")
      assert NomadVarsWriteSpy.write_calls() == 0
      assert_no_audit_event(:nomad_var_updated)
    end
  end

  describe "DEX-A06 — a failed save is never silent" do
    @tag action: "DEX-A06"
    test "a forced :unavailable save shows an explicit error, modal stays open, value not shown as saved",
         %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-description-edit") |> render_click()
      force_error(:nomad_vars, :unavailable)

      html =
        view
        |> form("#data-export-edit-form", value: %{"value" => "will not save"})
        |> render_submit()

      assert has_element?(view, "#data-export-edit-modal")
      assert has_element?(view, "#data-export-edit-error")
      assert html =~ "will not save"

      clear_faults()

      assert {:ok, %{items: %{"description" => original}}} =
               NomadVars.fetch(%Nucleus.Scope{
                 tenant: "local",
                 user: %{email: "a@b.com", username: nil}
               })

      assert original =~ "Nightly export"
      assert_no_audit_event(:nomad_var_updated)
    end

    @tag action: "DEX-A06"
    test "a forced :conflict save shows conflict-specific copy, distinct from the generic failure copy",
         %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-description-edit") |> render_click()
      force_error(:nomad_vars, :conflict)

      view
      |> form("#data-export-edit-form", value: %{"value" => "racing edit"})
      |> render_submit()

      conflict_html = view |> element("#data-export-edit-error") |> render()
      assert conflict_html =~ "changed since you loaded it"

      clear_faults()
      force_error(:nomad_vars, :unavailable)

      view
      |> form("#data-export-edit-form", value: %{"value" => "racing edit"})
      |> render_submit()

      unavailable_html = view |> element("#data-export-edit-error") |> render()
      refute unavailable_html =~ "changed since you loaded it"
    end

    @tag action: "DEX-A06"
    test "after a failed save, the user can retry (resubmit) and succeed", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-description-edit") |> render_click()
      force_error(:nomad_vars, :unavailable)

      view
      |> form("#data-export-edit-form", value: %{"value" => "retry me"})
      |> render_submit()

      assert has_element?(view, "#data-export-edit-error")

      clear_faults()

      view
      |> form("#data-export-edit-form", value: %{"value" => "retry me"})
      |> render_submit()

      assert has_element?(view, "#var-description-value", "retry me")
      refute has_element?(view, "#data-export-edit-modal")
    end

    @tag action: "DEX-A06"
    test "after a failed save, the user can cancel instead of retrying", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-description-edit") |> render_click()
      force_error(:nomad_vars, :unavailable)

      view
      |> form("#data-export-edit-form", value: %{"value" => "abandoned edit"})
      |> render_submit()

      assert has_element?(view, "#data-export-edit-error")

      view |> element("#data-export-cancel-edit") |> render_click()

      refute has_element?(view, "#data-export-edit-modal")
      refute has_element?(view, "#var-description-value", "abandoned edit")
    end
  end

  describe "server-side re-check — a mismatched phx-value-key is rejected" do
    @tag action: "DEX-A06"
    test "save_edit for a key other than the row currently open is rejected, no adapter call",
         %{conn: conn} do
      use_write_spy()
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-destination_bucket-edit") |> render_click()
      assert has_element?(view, "#data-export-edit-modal")

      render_click(view, "save_edit", %{
        "key" => "description",
        "value" => %{"value" => "attacker-value"}
      })

      assert NomadVarsWriteSpy.write_calls() == 0
      assert_no_audit_event(:nomad_var_updated)
      # the originally open row's modal is untouched by the rejected attempt.
      assert has_element?(view, "#data-export-edit-modal")
    end

    test "save_edit dispatched with no row open at all is rejected, no adapter call", %{
      conn: conn
    } do
      use_write_spy()
      {:ok, view, _html} = live_data_export(conn)

      render_click(view, "save_edit", %{
        "key" => "description",
        "value" => %{"value" => "attacker-value"}
      })

      assert NomadVarsWriteSpy.write_calls() == 0
      assert_no_audit_event(:nomad_var_updated)
    end
  end

  describe "DEX-A07 — open the environment picker" do
    @tag action: "DEX-A07"
    test "opening shows non-archived environments with current selection pre-selected", %{
      conn: conn
    } do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()

      assert has_element?(view, "#env-picker-modal")
      refute has_element?(view, "#env-picker-available-legacy-qa")
      assert has_element?(view, "#env-picker-selected-prod")
    end

    @tag action: "DEX-A07"
    test "the seeded archived fixture (legacy-qa) never appears in either list", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()

      refute has_element?(view, "#env-picker-available-legacy-qa")
      refute has_element?(view, "#env-picker-selected-legacy-qa")
    end

    @tag action: "DEX-A07"
    test "currently-included env_names entries render pre-selected, others available", %{
      conn: conn
    } do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()

      # seeded env_names value is "prod,staging" — see @seeded_keys above.
      assert has_element?(view, "#env-picker-selected-prod")
      assert has_element?(view, "#env-picker-selected-staging")
      assert has_element?(view, "#env-picker-available-dev")
      assert has_element?(view, "#env-picker-available-sandbox")
      refute has_element?(view, "#env-picker-available-prod")
      refute has_element?(view, "#env-picker-available-staging")
    end

    @tag action: "DEX-A07"
    test "opening when list_environments/1 fails shows an error flash, not a crash, and does not open the modal",
         %{conn: conn} do
      use_failing_tenant_api()
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()

      refute has_element?(view, "#env-picker-modal")
      assert render(view) =~ "Couldn&#39;t load environments right now."
    end

    @tag action: "DEX-A07"
    test "reopening after a discarded toggle re-derives pre-selection from the current stored value, not stale picker state",
         %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()
      view |> element("#env-picker-available-dev button") |> render_click()
      assert has_element?(view, "#env-picker-selected-dev")

      # dismiss without saving (structural half of DEX-A11 — Escape/backdrop).
      render_click(view, "cancel_env_picker", %{})
      refute has_element?(view, "#env-picker-modal")

      view |> element("#var-env_names-edit") |> render_click()

      refute has_element?(view, "#env-picker-selected-dev")
      assert has_element?(view, "#env-picker-available-dev")
    end
  end

  describe "DEX-A08 — select and deselect environments" do
    @tag action: "DEX-A08"
    test "clicking an available environment moves it to selected, and the count increments", %{
      conn: conn
    } do
      {:ok, view, _html} = live_data_export(conn)
      view |> element("#var-env_names-edit") |> render_click()

      assert view |> element("#env-picker-selected-count") |> render() =~ "(2)"

      view |> element("#env-picker-available-dev button") |> render_click()

      assert has_element?(view, "#env-picker-selected-dev")
      refute has_element?(view, "#env-picker-available-dev")
      assert view |> element("#env-picker-selected-count") |> render() =~ "(3)"
    end

    @tag action: "DEX-A08"
    test "clicking a selected environment moves it back to available, and the count decrements",
         %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)
      view |> element("#var-env_names-edit") |> render_click()

      view |> element("#env-picker-selected-prod button") |> render_click()

      assert has_element?(view, "#env-picker-available-prod")
      refute has_element?(view, "#env-picker-selected-prod")
      assert view |> element("#env-picker-selected-count") |> render() =~ "(1)"
    end

    @tag action: "DEX-A08"
    test "no adapter write call occurs from opening or toggling alone", %{conn: conn} do
      use_write_spy()
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()
      view |> element("#env-picker-available-dev button") |> render_click()
      view |> element("#env-picker-selected-dev button") |> render_click()

      assert NomadVarsWriteSpy.write_calls() == 0
      assert_no_audit_event(:env_names_updated)
    end
  end

  describe "DEX-A09 — filter the environment picker" do
    @tag action: "DEX-A09"
    test "typing a filter narrows both available and selected to matches only", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)
      view |> element("#var-env_names-edit") |> render_click()

      view
      |> element("#env-picker-filter-form")
      |> render_change(%{"query" => "prod"})

      assert has_element?(view, "#env-picker-selected-prod")
      refute has_element?(view, "#env-picker-selected-staging")
      refute has_element?(view, "#env-picker-available-dev")
      refute has_element?(view, "#env-picker-available-sandbox")
    end

    @tag action: "DEX-A09"
    test "clearing the filter restores the full lists", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)
      view |> element("#var-env_names-edit") |> render_click()

      view
      |> element("#env-picker-filter-form")
      |> render_change(%{"query" => "prod"})

      view
      |> element("#env-picker-filter-form")
      |> render_change(%{"query" => ""})

      assert has_element?(view, "#env-picker-selected-prod")
      assert has_element?(view, "#env-picker-selected-staging")
      assert has_element?(view, "#env-picker-available-dev")
      assert has_element?(view, "#env-picker-available-sandbox")
    end

    @tag action: "DEX-A09"
    test "no adapter write call occurs from filtering alone", %{conn: conn} do
      use_write_spy()
      {:ok, view, _html} = live_data_export(conn)
      view |> element("#var-env_names-edit") |> render_click()

      view
      |> element("#env-picker-filter-form")
      |> render_change(%{"query" => "prod"})

      assert NomadVarsWriteSpy.write_calls() == 0
    end
  end

  describe "env_names never renders an edit modal here" do
    @tag action: "DEX-A14"
    test "the env_names row's edit trigger opens the picker, never the inline edit modal", %{
      conn: conn
    } do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()

      assert has_element?(view, "#env-picker-modal")
      refute has_element?(view, "#data-export-edit-modal")
    end

    test "dispatching \"edit\" directly for env_names opens no modal", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      render_click(view, "edit", %{"key" => "env_names"})

      refute has_element?(view, "#data-export-edit-modal")
    end
  end

  describe "DEX-A10 — save the environment selection as an explicit delta" do
    @tag action: "DEX-A10"
    test "saving updates env_names and the table reflects the new value; the picker closes",
         %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()
      view |> element("#env-picker-available-dev button") |> render_click()
      view |> element("#env-picker-save") |> render_click()

      refute has_element?(view, "#env-picker-modal")
      assert has_element?(view, "#var-env_names-value", "dev")
      assert has_element?(view, "#var-env_names-value", "prod")
      assert has_element?(view, "#var-env_names-value", "staging")
    end

    @tag action: "DEX-A10"
    test "emits env_names_updated with the added/removed delta, and no nomad_var_updated",
         %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()
      view |> element("#env-picker-available-dev button") |> render_click()
      view |> element("#env-picker-selected-staging button") |> render_click()
      view |> element("#env-picker-save") |> render_click()

      assert_audit_event(:env_names_updated,
        tenant: "local",
        details: %{added: ["dev"], removed: ["staging"]}
      )

      assert_no_audit_event(:nomad_var_updated)
    end

    @tag action: "DEX-A10"
    test "a forced :conflict on save keeps the picker open with the conflict-specific error, table unchanged",
         %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()
      view |> element("#env-picker-available-dev button") |> render_click()
      force_error(:nomad_vars, :conflict)

      view |> element("#env-picker-save") |> render_click()

      assert has_element?(view, "#env-picker-modal")
      assert has_element?(view, "#env-picker-error")
      assert view |> element("#env-picker-error") |> render() =~ "changed since you loaded it"
      assert has_element?(view, "#var-env_names-value", "prod")
      refute has_element?(view, "#var-env_names-value", "dev")

      clear_faults()
      assert_no_audit_event(:env_names_updated)
    end

    @tag action: "DEX-A10"
    test "after a forced-failure save, the user can retry and succeed", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()
      view |> element("#env-picker-available-dev button") |> render_click()
      force_error(:nomad_vars, :unavailable)

      view |> element("#env-picker-save") |> render_click()
      assert has_element?(view, "#env-picker-error")

      clear_faults()

      view |> element("#env-picker-save") |> render_click()

      refute has_element?(view, "#env-picker-modal")
      assert has_element?(view, "#var-env_names-value", "dev")
    end

    @tag action: "DEX-A10"
    test "deselecting every environment and saving succeeds — an empty selection is valid, not rejected",
         %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()
      view |> element("#env-picker-selected-prod button") |> render_click()
      view |> element("#env-picker-selected-staging button") |> render_click()
      view |> element("#env-picker-save") |> render_click()

      refute has_element?(view, "#env-picker-modal")
      refute has_element?(view, "#env-picker-error")

      assert_audit_event(:env_names_updated,
        tenant: "local",
        details: %{added: [], removed: ["prod", "staging"]}
      )
    end

    @tag action: "DEX-A10"
    test "firing save_env_picker with no picker open is a no-op, not a crash", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      refute has_element?(view, "#env-picker-modal")

      render_click(view, "save_env_picker", %{})

      refute has_element?(view, "#env-picker-modal")
      assert_no_audit_event(:env_names_updated)
    end
  end

  describe "DEX-A11 — cancel the environment picker without saving" do
    @tag action: "DEX-A11"
    test "clicking Cancel closes the picker with no adapter write call and no audit event; env_names unchanged",
         %{conn: conn} do
      use_write_spy()
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()
      view |> element("#env-picker-available-dev button") |> render_click()
      assert has_element?(view, "#env-picker-selected-dev")

      view |> element("#env-picker-cancel") |> render_click()

      refute has_element?(view, "#env-picker-modal")
      assert has_element?(view, "#var-env_names-value", "prod")
      assert has_element?(view, "#var-env_names-value", "staging")
      refute has_element?(view, "#var-env_names-value", "dev")
      assert NomadVarsWriteSpy.write_calls() == 0
      assert_no_audit_event(:env_names_updated)
    end

    @tag action: "DEX-A11"
    test "dismissing via the modal's structural on_cancel path (Escape/backdrop) has the identical no-op effect as Cancel",
         %{conn: conn} do
      use_write_spy()
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()
      view |> element("#env-picker-available-dev button") |> render_click()

      # Claims only the `on_cancel` handler path this pushes to
      # (`"cancel_env_picker"`) — the genuine keyboard Escape keypress and a
      # real backdrop click are the standing browser-only gap recorded in
      # `test/README.md`, mirroring `SEC-A04`/`SEC-A13`'s own gaps.
      render_click(view, "cancel_env_picker", %{})

      refute has_element?(view, "#env-picker-modal")
      assert has_element?(view, "#var-env_names-value", "prod")
      refute has_element?(view, "#var-env_names-value", "dev")
      assert NomadVarsWriteSpy.write_calls() == 0
      assert_no_audit_event(:env_names_updated)
    end

    @tag action: "DEX-A11"
    test "reopening the picker after a cancel pre-selects from the original, unaffected value",
         %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()
      view |> element("#env-picker-available-dev button") |> render_click()
      view |> element("#env-picker-selected-staging button") |> render_click()

      view |> element("#env-picker-cancel") |> render_click()

      view |> element("#var-env_names-edit") |> render_click()

      assert has_element?(view, "#env-picker-selected-prod")
      assert has_element?(view, "#env-picker-selected-staging")
      refute has_element?(view, "#env-picker-selected-dev")
      assert has_element?(view, "#env-picker-available-dev")
    end

    @tag action: "DEX-A11"
    test "cancelling after a failed save also discards the picker with no further effect",
         %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-env_names-edit") |> render_click()
      view |> element("#env-picker-available-dev button") |> render_click()
      force_error(:nomad_vars, :unavailable)
      view |> element("#env-picker-save") |> render_click()
      assert has_element?(view, "#env-picker-error")

      clear_faults()
      view |> element("#env-picker-cancel") |> render_click()

      refute has_element?(view, "#env-picker-modal")
      assert has_element?(view, "#var-env_names-value", "prod")
      refute has_element?(view, "#var-env_names-value", "dev")
    end
  end

  defmodule EnvPickerModalBrowserGaps do
    @moduledoc """
    `DEX-A11`'s Escape and backdrop-click dismissal reach the server only by
    running the `Phoenix.LiveView.JS` chain in `<.modal>`'s `data-cancel`
    attribute (`core_components.ex:645`), which needs a real key event, a
    real click outside `.modal-box`, and a client to interpret the command
    list — `Phoenix.LiveViewTest` cannot execute any of that
    (`docs/adr/0008-test-strategy.md`), the exact reason `SEC-A04`'s and
    `SEC-A13`'s own modal gaps exist.

    The `"DEX-A11 — ..."` describe block above proves the one route
    `render_click/1` can actually drive (the explicit Cancel button, a
    plain `phx-click`) discards cleanly, and proves the `on_cancel` handler
    itself is a genuine no-op when reached directly. What remains
    unverified here is the same as `SecretRevealModalBrowserGaps`'/
    `NewSecretModalBrowserGaps`' own gap, carried in `living-notes.md`
    alongside `SEC-A02`'s and `SEC-A04`'s.

    Skipped unconditionally rather than by default-exclude tag, so `mix
    test` always reports them as skipped instead of silently passing zero
    assertions. None carry `@tag action:` — the describe block above
    records what is actually proven.
    """

    use ExUnit.Case, async: true

    @moduletag :browser
    @moduletag skip: "no browser driver in this repo — see docs/adr/0008-test-strategy.md"

    test "pressing Escape while the picker is open closes it and saves nothing" do
    end

    test "clicking the backdrop outside the picker box closes it and saves nothing" do
    end

    test "focus moves into the picker on open and returns to #var-env_names-edit on dismissal" do
    end

    test "Tab is trapped inside the picker while it is open" do
    end
  end
end
