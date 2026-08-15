defmodule NucleusWeb.SecretsLiveTest do
  # `force_error/2` (`Nucleus.BackendCase`) mutates node-global state.
  use NucleusWeb.LiveCase, async: false

  describe "SEC-A16 — reject a well-formed but unknown environment" do
    @tag action: "SEC-A16"
    test "renders environment-not-found", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "nope")

      assert has_element?(view, "#secrets-environment-not-found")
      refute has_element?(view, "#secrets-table")
    end
  end

  describe "SEC-A15 — reject an invalid environment name" do
    @tag action: "SEC-A15"
    test "renders invalid-environment for path-traversal characters", %{conn: conn} do
      assert {:ok, view, _html} = live(conn, "/environments/..%2f..%2fetc/secrets")

      assert has_element?(view, "#secrets-invalid-environment")
      refute has_element?(view, "#secrets-table")
    end
  end

  describe "SEC-A17 — fail closed when environment validation is unavailable" do
    @tag action: "SEC-A17"
    test "renders validation-unavailable, distinct from not-found", %{conn: conn} do
      force_error(:tenant_api, :unavailable)

      assert {:ok, view, _html} = live_secrets(conn, "prod")

      assert has_element?(view, "#secrets-validation-unavailable")
      refute has_element?(view, "#secrets-environment-not-found")
      refute has_element?(view, "#secrets-table")
    end
  end

  describe "all three states keep the shell intact" do
    test "invalid name still renders the shell and no secrets controls", %{conn: conn} do
      assert {:ok, view, _html} = live(conn, "/environments/..%2f..%2fetc/secrets")

      assert has_element?(view, "#tenant-identifier")
      refute has_element?(view, "#secrets-table")
      refute has_element?(view, "#secrets-create-button")
    end

    test "not-found still renders the shell and no secrets controls", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "nope")

      assert has_element?(view, "#tenant-identifier")
      refute has_element?(view, "#secrets-table")
      refute has_element?(view, "#secrets-create-button")
    end

    test "unavailable still renders the shell and no secrets controls", %{conn: conn} do
      force_error(:tenant_api, :unavailable)

      assert {:ok, view, _html} = live_secrets(conn, "prod")

      assert has_element?(view, "#tenant-identifier")
      refute has_element?(view, "#secrets-table")
      refute has_element?(view, "#secrets-create-button")
    end
  end

  describe "patching between environments re-validates" do
    test "patching from a valid environment to an invalid one re-renders as invalid", %{
      conn: conn
    } do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      refute has_element?(view, "#secrets-invalid-environment")

      html = render_patch(view, "/environments/..%2f..%2fetc/secrets")

      assert html =~ ~s(id="secrets-invalid-environment")
      assert has_element?(view, "#secrets-invalid-environment")
    end

    test "patching from a valid environment to an unknown one re-renders as not-found", %{
      conn: conn
    } do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      render_patch(view, "/environments/nope/secrets")

      assert has_element?(view, "#secrets-environment-not-found")
    end
  end
end
