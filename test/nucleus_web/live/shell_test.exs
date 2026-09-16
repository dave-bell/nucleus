defmodule NucleusWeb.ShellTest do
  # Mutates :nucleus, :backends application config and the LOCAL_FORCE_ERROR
  # env var, both global.
  use NucleusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import NucleusWeb.LiveCase

  @endpoint NucleusWeb.Endpoint

  defmodule EmptyTenantApi do
    @moduledoc "Stands in for a tenant with zero environments."
    @behaviour Nucleus.TenantApi

    @impl Nucleus.TenantApi
    def list_environments(_token), do: {:ok, []}

    @impl Nucleus.TenantApi
    def health_check, do: :ok
  end

  defmodule CollidingCategoriesTenantApi do
    @moduledoc """
    Stands in for a tenant whose category names differ only by case or
    punctuation ("Prod East", "Prod-East", "PROD_EAST") — three distinct
    groups per `NucleusWeb.SidebarEnvironments.group/1`, which would collide
    on the same `category_slug`-derived DOM id (`"prod-east"`) without
    `SidebarEnvironments.with_slugs/1`'s disambiguation.
    """
    @behaviour Nucleus.TenantApi

    @impl Nucleus.TenantApi
    def list_environments(_token) do
      {:ok,
       [
         %Nucleus.TenantApi.Environment{short_name: "east-1", categories: ["Prod East"]},
         %Nucleus.TenantApi.Environment{short_name: "east-2", categories: ["Prod-East"]},
         %Nucleus.TenantApi.Environment{short_name: "east-3", categories: ["PROD_EAST"]}
       ]}
    end

    @impl Nucleus.TenantApi
    def health_check, do: :ok
  end

  setup do
    original_backends = Application.get_env(:nucleus, :backends)

    on_exit(fn ->
      Application.put_env(:nucleus, :backends, original_backends)
      System.delete_env("LOCAL_FORCE_ERROR")
    end)

    :ok
  end

  defp put_tenant_api(module) do
    configured = Application.get_env(:nucleus, :backends, [])
    Application.put_env(:nucleus, :backends, Keyword.put(configured, :tenant_api, module))
  end

  @tag :unit
  test "shows the tenant identifier", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    assert has_element?(view, "#tenant-identifier", "local")
  end

  @tag :unit
  @tag action: "NAV-A02"
  test "the tenant identifier is present regardless of which feature is viewed", %{conn: conn} do
    {:ok, applications_view, _html} = live_applications(conn)
    assert has_element?(applications_view, "#tenant-identifier")

    {:ok, data_export_view, _html} = live_data_export(conn)
    assert has_element?(data_export_view, "#tenant-identifier")

    {:ok, m2m_clients_view, _html} = live_m2m_clients(conn)
    assert has_element?(m2m_clients_view, "#tenant-identifier")

    {:ok, environment_view, _html} = live_environment(conn, "prod")
    assert has_element?(environment_view, "#tenant-identifier")

    {:ok, secrets_view, _html} = live_secrets(conn, "prod")
    assert has_element?(secrets_view, "#tenant-identifier")
  end

  @tag :unit
  @tag action: "NAV-A03"
  test "visiting /applications highlights only #nav-applications", %{conn: conn} do
    {:ok, view, _html} = live_applications(conn)

    assert has_element?(view, ~s(#nav-applications[aria-current="page"]))
    refute has_element?(view, ~s(#nav-data-export[aria-current="page"]))
    refute has_element?(view, ~s(#nav-m2m-clients[aria-current="page"]))
  end

  @tag :unit
  @tag action: "NAV-A03"
  test "visiting / (the same view as /applications) highlights only #nav-applications", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, ~s(#nav-applications[aria-current="page"]))
    refute has_element?(view, ~s(#nav-data-export[aria-current="page"]))
    refute has_element?(view, ~s(#nav-m2m-clients[aria-current="page"]))
  end

  @tag :unit
  @tag action: "NAV-A03"
  test "visiting /data-export highlights only #nav-data-export", %{conn: conn} do
    {:ok, view, _html} = live_data_export(conn)

    assert has_element?(view, ~s(#nav-data-export[aria-current="page"]))
    refute has_element?(view, ~s(#nav-applications[aria-current="page"]))
    refute has_element?(view, ~s(#nav-m2m-clients[aria-current="page"]))
  end

  @tag :unit
  @tag action: "NAV-A03"
  test "visiting /m2m/clients highlights only #nav-m2m-clients", %{conn: conn} do
    {:ok, view, _html} = live_m2m_clients(conn)

    assert has_element?(view, ~s(#nav-m2m-clients[aria-current="page"]))
    refute has_element?(view, ~s(#nav-applications[aria-current="page"]))
    refute has_element?(view, ~s(#nav-data-export[aria-current="page"]))
  end

  @tag :unit
  @tag action: "NAV-A03"
  test "visiting an environment detail or secrets page highlights none of the three tenant-wide links",
       %{conn: conn} do
    {:ok, environment_view, _html} = live_environment(conn, "prod")

    refute has_element?(environment_view, ~s(#nav-applications[aria-current="page"]))
    refute has_element?(environment_view, ~s(#nav-data-export[aria-current="page"]))
    refute has_element?(environment_view, ~s(#nav-m2m-clients[aria-current="page"]))

    {:ok, secrets_view, _html} = live_secrets(conn, "prod")

    refute has_element?(secrets_view, ~s(#nav-applications[aria-current="page"]))
    refute has_element?(secrets_view, ~s(#nav-data-export[aria-current="page"]))
    refute has_element?(secrets_view, ~s(#nav-m2m-clients[aria-current="page"]))
  end

  @tag :unit
  test "sidebar is open (not collapsed) by default, with a toggle control", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    assert has_element?(view, ~s(#shell[data-collapsed="false"]))
    assert has_element?(view, "#sidebar-toggle")
  end

  @tag :unit
  test "sidebar's collapsed rail carries one icon per section", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    assert has_element?(view, ~s([title="Tenant"]))
    assert has_element?(view, ~s([title="Environments"]))
  end

  @tag :unit
  test "the sidebar M2M Clients item is a real link and navigates to this view", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    assert {:ok, m2m_view, _html} =
             view
             |> element("#nav-m2m-clients")
             |> render_click()
             |> follow_redirect(conn, ~p"/m2m/clients")

    assert has_element?(m2m_view, "#tenant-identifier")
  end

  @tag :unit
  test "the sidebar Data Export item is a real link and navigates to this view", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    assert {:ok, data_export_view, _html} =
             view
             |> element("#nav-data-export")
             |> render_click()
             |> follow_redirect(conn, ~p"/data-export")

    assert has_element?(data_export_view, "#tenant-identifier")
  end

  describe "NAV-A08 — identity control" do
    @tag :unit
    @tag action: "NAV-A08"
    test "#user-menu-panel is absent before toggle-user-menu, present after", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

      refute has_element?(view, "#user-menu-panel")

      render_click(view, "toggle-user-menu")

      assert has_element?(view, "#user-menu-panel")
    end

    @tag :unit
    @tag action: "NAV-A08"
    test "#user-menu carries daisyUI's dropdown-open class once open, not just the panel's presence",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

      # daisyUI's `.dropdown` component hides `.dropdown-content` via CSS
      # unless the container is `:focus-within` or carries `.dropdown-open`
      # — `.dropdown-content` being present in the DOM (`:if=`) is not
      # sufficient on its own for it to actually be visible, since a
      # `phx-click` round-trip gives no cross-browser guarantee the trigger
      # button keeps real focus afterwards (Safari never focuses a clicked
      # `<button>` at all). Regression test for that gap.
      refute has_element?(view, "#user-menu.dropdown-open")

      render_click(view, "toggle-user-menu")

      assert has_element?(view, "#user-menu.dropdown-open")

      render_click(view, "toggle-user-menu")

      refute has_element?(view, "#user-menu.dropdown-open")
    end

    @tag :unit
    @tag action: "NAV-A08"
    test "shows the identity control with the dev email, and now a Logout control (inverts the pre-NAV-S3 refutes)",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

      render_click(view, "toggle-user-menu")

      assert has_element?(view, "#user-menu", "test-dev@example.com")
      assert has_element?(view, ~s(#user-menu-logout[data-method="delete"][data-to="/logout"]))
    end

    @tag :unit
    @tag action: "NAV-A08"
    test "pressing Escape closes the open panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

      render_click(view, "toggle-user-menu")
      assert has_element?(view, "#user-menu-panel")

      render_keydown(view, "close-user-menu", %{"key" => "Escape"})

      refute has_element?(view, "#user-menu-panel")
    end

    @tag :unit
    @tag action: "NAV-A08"
    test "click-away binds to #user-menu (which contains the trigger button), not #user-menu-panel alone, and only while open",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

      # Regression test for a real-browser bug that `has_element?/2` alone
      # never caught: `Phoenix.LiveView`'s JS dispatches click-away *before*
      # the clicked element's own `phx-click`. The trigger button is a
      # sibling of `#user-menu-panel`, not its descendant — binding
      # click-away to the panel alone means a click on the trigger button
      # while open is "away" from the panel, so it would push
      # `close-user-menu` and then `toggle-user-menu` for the same click,
      # reopening what it just closed. Binding to `#user-menu` (which
      # contains both) makes a click on the button "contained", not
      # "away". The binding is also conditional on `@user_menu_open?`
      # itself — asserted here as absent while closed — since `#user-menu`
      # is otherwise mounted for every authenticated request, and an
      # unconditional binding would push `close-user-menu` on every click
      # anywhere on the page.
      refute has_element?(view, ~s(#user-menu[phx-click-away]))

      render_click(view, "toggle-user-menu")

      assert has_element?(view, ~s(#user-menu[phx-click-away="close-user-menu"]))
      refute has_element?(view, ~s(#user-menu-panel[phx-click-away]))
    end

    @tag :unit
    @tag action: "NAV-A08"
    test "the scopes block is gone, even for a scope with a non-empty scopes list", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

      render_click(view, "toggle-user-menu")

      refute has_element?(view, "#user-menu", "Scopes")
      refute has_element?(view, "#user-menu", "No scopes granted")
    end
  end

  @tag :unit
  @tag action: "NAV-A04"
  test "lists non-archived environments grouped by category, with per-category counts, archived excluded",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    assert has_element?(view, "#environment-category-customer-facing-toggle", "Customer Facing")
    assert has_element?(view, "#environment-category-customer-facing-toggle", "1")
    assert has_element?(view, "#environment-category-regulated-toggle", "Regulated")
    assert has_element?(view, "#environment-category-pre-production-toggle", "Pre-Production")
    assert has_element?(view, "#environment-category-experimental-toggle", "Experimental")
    assert has_element?(view, "#environment-category-uncategorized-toggle", "Uncategorized")
    assert has_element?(view, "#environment-category-uncategorized-toggle", "1")

    # legacy-qa is archived and categorized as "Deprecated" — the group
    # itself must not exist, not merely be empty.
    refute has_element?(view, "#environment-category-deprecated-toggle")
    refute has_element?(view, "[id^=environment-category-]", "Legacy QA")
  end

  @tag :unit
  @tag action: "NAV-A04"
  test "categories differing only by case or punctuation get distinct DOM ids and independent expand state",
       %{conn: conn} do
    put_tenant_api(CollidingCategoriesTenantApi)

    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    assert has_element?(view, "#environment-category-prod-east-toggle", "Prod East")
    assert has_element?(view, "#environment-category-prod-east-2-toggle", "Prod-East")
    assert has_element?(view, "#environment-category-prod-east-3-toggle", "PROD_EAST")

    render_click(element(view, "#environment-category-prod-east-toggle"))

    assert has_element?(view, "#environment-category-prod-east-list", "east-1")
    refute has_element?(view, "#environment-category-prod-east-2-list")
    refute has_element?(view, "#environment-category-prod-east-3-list")
  end

  @tag :unit
  @tag action: "NAV-A05"
  test "a collapsed category starts with no navigable links rendered, expands to reveal them, and collapses again",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    toggle = element(view, "#environment-category-pre-production-toggle")

    assert has_element?(
             view,
             ~s(#environment-category-pre-production-toggle[aria-expanded="false"])
           )

    refute has_element?(view, "#environment-category-pre-production-list")

    render_click(toggle)

    assert has_element?(
             view,
             ~s(#environment-category-pre-production-toggle[aria-expanded="true"])
           )

    assert has_element?(view, "#environment-category-pre-production-list", "Staging")

    render_click(toggle)

    assert has_element?(
             view,
             ~s(#environment-category-pre-production-toggle[aria-expanded="false"])
           )

    refute has_element?(view, "#environment-category-pre-production-list")
  end

  @tag :unit
  @tag action: "NAV-A05"
  test "two categories expand and collapse independently", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    render_click(element(view, "#environment-category-pre-production-toggle"))

    assert has_element?(view, "#environment-category-pre-production-list", "Staging")
    refute has_element?(view, "#environment-category-experimental-list")

    render_click(element(view, "#environment-category-experimental-toggle"))

    assert has_element?(view, "#environment-category-pre-production-list", "Staging")
    assert has_element?(view, "#environment-category-experimental-list", "Sandbox")

    render_click(element(view, "#environment-category-pre-production-toggle"))

    refute has_element?(view, "#environment-category-pre-production-list")
    assert has_element?(view, "#environment-category-experimental-list", "Sandbox")
  end

  @tag :unit
  @tag action: "NAV-A06"
  test "selecting an environment link inside an expanded category navigates to its detail view",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    render_click(element(view, "#environment-category-pre-production-toggle"))

    assert {:ok, detail_view, _html} =
             view
             |> element("#environment-category-pre-production-list a", "Staging")
             |> render_click()
             |> follow_redirect(conn, ~p"/environments/staging")

    assert has_element?(detail_view, "#environment-detail")
  end

  @tag :unit
  @tag action: "ENV-A01"
  test "expanding a category and selecting an environment reaches its detail view", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    render_click(element(view, "#environment-category-pre-production-toggle"))

    assert {:ok, detail_view, _html} =
             view
             |> element("#environment-category-pre-production-list a", "Staging")
             |> render_click()
             |> follow_redirect(conn, ~p"/environments/staging")

    assert has_element?(detail_view, "#environment-detail")
  end

  @tag :unit
  test "a category stays expanded after selecting one of its children — the child link remounts the LiveView, which must not collapse it",
       %{conn: conn} do
    # A real browser's `navigate` never repeats the `:assign_scope` plug — the
    # session (and so `nav_session_id`) is fixed as of the socket's original
    # HTTP page load, before the websocket ever connects. `follow_redirect/2`
    # simulates a `navigate` as an entirely fresh HTTP request through the
    # router, so this primes `conn` with that same cookie first — otherwise
    # the simulated "remount" would look like a brand new browser with no
    # session at all, which no real navigate ever produces.
    conn = get(conn, ~p"/environments/prod/secrets")

    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    render_click(element(view, "#environment-category-pre-production-toggle"))

    assert {:ok, detail_view, _html} =
             view
             |> element("#environment-category-pre-production-list a", "Staging")
             |> render_click()
             |> follow_redirect(conn, ~p"/environments/staging")

    render_async(detail_view)

    assert has_element?(
             detail_view,
             ~s(#environment-category-pre-production-toggle[aria-expanded="true"])
           )

    assert has_element?(detail_view, "#environment-category-pre-production-list", "Staging")
  end

  @tag :unit
  test "a second category expanded before navigating is also still expanded after", %{
    conn: conn
  } do
    conn = get(conn, ~p"/environments/prod/secrets")

    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    render_click(element(view, "#environment-category-pre-production-toggle"))
    render_click(element(view, "#environment-category-experimental-toggle"))

    assert {:ok, detail_view, _html} =
             view
             |> element("#environment-category-pre-production-list a", "Staging")
             |> render_click()
             |> follow_redirect(conn, ~p"/environments/staging")

    render_async(detail_view)

    assert has_element?(
             detail_view,
             ~s(#environment-category-experimental-toggle[aria-expanded="true"])
           )

    assert has_element?(detail_view, "#environment-category-experimental-list", "Sandbox")
  end

  @tag :unit
  test "two independent browser sessions never share expanded-category state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    render_click(element(view, "#environment-category-pre-production-toggle"))

    other_conn = Phoenix.ConnTest.build_conn()
    {:ok, other_view, _html} = live(other_conn, ~p"/environments/prod/secrets")

    render_async(other_view)

    assert has_element?(
             view,
             ~s(#environment-category-pre-production-toggle[aria-expanded="true"])
           )

    assert has_element?(
             other_view,
             ~s(#environment-category-pre-production-toggle[aria-expanded="false"])
           )
  end

  @tag :unit
  test "an archived environment stays reachable by direct URL, even though hidden from the sidebar",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/legacy-qa/secrets")

    render_async(view)

    # SEC-S1's validation ladder resolves it (ENV-A06), not treated as an error.
    refute has_element?(view, "#secrets-environment-not-found")
    refute has_element?(view, "#secrets-invalid-environment")
    refute has_element?(view, "#secrets-validation-unavailable")
    refute has_element?(view, "#environment-category-deprecated-toggle")
  end

  @tag :unit
  @tag action: "NAV-A07"
  test "shows the empty state when there are no environments", %{conn: conn} do
    put_tenant_api(EmptyTenantApi)

    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    assert has_element?(view, "#environments-empty")
    refute has_element?(view, "[id^=environment-category-]")
  end

  @tag :unit
  @tag action: "NAV-A07"
  test "LOCAL_FORCE_ERROR=unavailable degrades to the same empty state, not an error", %{
    conn: conn
  } do
    System.put_env("LOCAL_FORCE_ERROR", "unavailable")

    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    assert has_element?(view, "#environments-empty")
    refute has_element?(view, "[id^=environment-category-]")
    # The shell itself still renders — a failed environment load never blocks
    # navigation (NAV-A07).
    assert has_element?(view, "#tenant-identifier")
    assert has_element?(view, "#user-menu")
  end

  @tag :unit
  test "rendered HTML never contains a token", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    # Scoped to where current_scope is actually rendered (the identity
    # control) — the full page also contains the unrelated csrf-token meta
    # tag, so a whole-document substring check would false-positive.
    refute has_element?(view, "#user-menu", "token")
  end
end
