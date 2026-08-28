defmodule NucleusWeb.DataExportLiveTest do
  # `force_error/2`/`Nucleus.Backend.Seed.write/2` mutate node-global state
  # (`Nucleus.Backend.Faults`, `Nucleus.Backend.Seed`) — matching
  # `Nucleus.BackendCase`'s own `async: false` requirement.
  use NucleusWeb.LiveCase, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Seed

  # Seeded in priv/backends/local_seed.json under TENANT_NAMESPACE = "local".
  @seeded_path "nomad/jobs/local-data_export"
  @seeded_keys ["description", "env_names", "destination_bucket"]

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
end
