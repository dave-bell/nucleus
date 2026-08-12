defmodule NucleusWeb.ShellTest do
  # Mutates :nucleus, :backends application config and the LOCAL_FORCE_ERROR
  # env var, both global.
  use NucleusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @endpoint NucleusWeb.Endpoint

  defmodule EmptyTenantApi do
    @moduledoc "Stands in for a tenant with zero environments."
    @behaviour Nucleus.TenantApi

    @impl Nucleus.TenantApi
    def list_environments(_token), do: {:ok, []}

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
  test "shows the identity control with the dev email, and no sign-out control", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    assert has_element?(view, "#user-menu", "test-dev@example.com")
    refute has_element?(view, "#user-menu", "Sign out")
    refute has_element?(view, "#user-menu", "Log out")
    refute has_element?(view, "#user-menu", "Logout")
  end

  @tag :unit
  test "lists non-archived environments from the local backend, archived excluded", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    assert has_element?(view, "#environments-list", "Production")
    assert has_element?(view, "#environments-list", "Staging")
    assert has_element?(view, "#environments-list", "Development")
    assert has_element?(view, "#environments-list", "Sandbox")
    refute has_element?(view, "#environments-list", "Legacy QA")
  end

  @tag :unit
  test "an archived environment stays reachable by direct URL, even though hidden from the sidebar",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/environments/legacy-qa/secrets")

    render_async(view)

    assert has_element?(view, "#secrets-not-implemented")
    refute has_element?(view, "#environments-list", "Legacy QA")
  end

  @tag :unit
  test "shows the empty state when there are no environments", %{conn: conn} do
    put_tenant_api(EmptyTenantApi)

    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    assert has_element?(view, "#environments-empty")
    refute has_element?(view, "#environments-list")
  end

  @tag :unit
  test "LOCAL_FORCE_ERROR=unavailable degrades to the same empty state, not an error", %{
    conn: conn
  } do
    System.put_env("LOCAL_FORCE_ERROR", "unavailable")

    {:ok, view, _html} = live(conn, ~p"/environments/prod/secrets")

    render_async(view)

    assert has_element?(view, "#environments-empty")
    refute has_element?(view, "#environments-list")
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
