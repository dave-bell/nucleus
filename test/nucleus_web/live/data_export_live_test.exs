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

      assert has_element?(view, "#var-description-edit-form")

      view
      |> form("#var-description-edit-form", value: %{"value" => "Updated description."})
      |> render_submit()

      assert has_element?(view, "#var-description-value", "Updated description.")
      refute has_element?(view, "#var-description-edit-form")
      assert has_element?(view, "#flash-info")
    end

    @tag action: "DEX-A04"
    test "the underlying store reflects the new value, and the audit event carries no value", %{
      conn: conn
    } do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-description-edit") |> render_click()

      view
      |> form("#var-description-edit-form", value: %{"value" => "Nightly export v2."})
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
      |> form("#var-destination_bucket-edit-form", value: %{"value" => "acme-analytics-v2"})
      |> render_submit()

      assert has_element?(view, "#var-destination_bucket-value", "acme-analytics-v2")
    end

    @tag action: "DEX-A05"
    test "cancel discards the edit; original value remains, no adapter call", %{conn: conn} do
      use_write_spy()
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-destination_bucket-edit") |> render_click()
      assert has_element?(view, "#var-destination_bucket-edit-form")

      view
      |> form("#var-destination_bucket-edit-form", value: %{"value" => "not-going-to-be-saved"})
      |> render_change()

      view |> element("#var-destination_bucket-cancel-edit") |> render_click()

      refute has_element?(view, "#var-destination_bucket-edit-form")
      assert has_element?(view, "#var-destination_bucket-value", "acme-analytics-prod")
      assert NomadVarsWriteSpy.write_calls() == 0
      assert_no_audit_event(:nomad_var_updated)
    end
  end

  describe "DEX-A06 — a failed save is never silent" do
    @tag action: "DEX-A06"
    test "a forced :unavailable save shows an explicit error, form stays open, value not shown as saved",
         %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-description-edit") |> render_click()
      force_error(:nomad_vars, :unavailable)

      html =
        view
        |> form("#var-description-edit-form", value: %{"value" => "will not save"})
        |> render_submit()

      assert has_element?(view, "#var-description-edit-form")
      assert has_element?(view, "#var-description-edit-error")
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
      |> form("#var-description-edit-form", value: %{"value" => "racing edit"})
      |> render_submit()

      conflict_html = view |> element("#var-description-edit-error") |> render()
      assert conflict_html =~ "changed since you loaded it"

      clear_faults()
      force_error(:nomad_vars, :unavailable)

      view
      |> form("#var-description-edit-form", value: %{"value" => "racing edit"})
      |> render_submit()

      unavailable_html = view |> element("#var-description-edit-error") |> render()
      refute unavailable_html =~ "changed since you loaded it"
    end

    @tag action: "DEX-A06"
    test "after a failed save, the user can retry (resubmit) and succeed", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-description-edit") |> render_click()
      force_error(:nomad_vars, :unavailable)

      view
      |> form("#var-description-edit-form", value: %{"value" => "retry me"})
      |> render_submit()

      assert has_element?(view, "#var-description-edit-error")

      clear_faults()

      view
      |> form("#var-description-edit-form", value: %{"value" => "retry me"})
      |> render_submit()

      assert has_element?(view, "#var-description-value", "retry me")
      refute has_element?(view, "#var-description-edit-form")
    end

    @tag action: "DEX-A06"
    test "after a failed save, the user can cancel instead of retrying", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      view |> element("#var-description-edit") |> render_click()
      force_error(:nomad_vars, :unavailable)

      view
      |> form("#var-description-edit-form", value: %{"value" => "abandoned edit"})
      |> render_submit()

      assert has_element?(view, "#var-description-edit-error")

      view |> element("#var-description-cancel-edit") |> render_click()

      refute has_element?(view, "#var-description-edit-form")
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
      assert has_element?(view, "#var-destination_bucket-edit-form")

      render_click(view, "save_edit", %{
        "key" => "description",
        "value" => %{"value" => "attacker-value"}
      })

      assert NomadVarsWriteSpy.write_calls() == 0
      assert_no_audit_event(:nomad_var_updated)
      # the originally open row's form is untouched by the rejected attempt.
      assert has_element?(view, "#var-destination_bucket-edit-form")
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

  describe "env_names never renders an inline edit form here" do
    @tag action: "DEX-A14"
    test "no edit trigger exists on the env_names row", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      refute has_element?(view, "#var-env_names-edit")
    end

    test "dispatching \"edit\" directly for env_names opens no form", %{conn: conn} do
      {:ok, view, _html} = live_data_export(conn)

      render_click(view, "edit", %{"key" => "env_names"})

      refute has_element?(view, "#var-env_names-edit-form")
    end
  end
end
