defmodule NucleusWeb.EnvironmentsLiveTest do
  # `seed_environment/1` and the backend swap below both mutate node-global
  # state (`Nucleus.Backend.Seed`, `:nucleus, :backends`).
  use NucleusWeb.LiveCase, async: false

  alias Nucleus.Backend.Error

  defmodule FailingTenantApi do
    @moduledoc """
    A `Nucleus.TenantApi` implementation whose `list_environments/1` always
    fails with a controllable `Nucleus.Backend.Error` — the same swapped-module
    technique `Nucleus.EnvironmentsTest.ExplodingTenantApi` and
    `Nucleus.M2MTest.FailingM2MClients` use.

    `LOCAL_FORCE_ERROR` (`Nucleus.Backend.Faults`) is node-global and would
    also be picked up by `NucleusWeb.EnvironmentsHook`'s own call to the same
    `:tenant_api` boundary on the very same mount, and by any other
    `async: false` test in the same run — a swapped module is the only way
    to control the returned kind precisely, per test.
    """
    @behaviour Nucleus.TenantApi

    @impl Nucleus.TenantApi
    def list_environments(_token) do
      kind = Application.get_env(:nucleus, __MODULE__, :unavailable)
      {:error, Error.new(kind, :tenant_api, "forced for test", %{})}
    end

    @impl Nucleus.TenantApi
    def health_check, do: raise("should not be called")
  end

  defp use_failing_tenant_api(kind) do
    original = Application.get_env(:nucleus, :backends, [])
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)

    Application.put_env(:nucleus, FailingTenantApi, kind)

    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(original, :tenant_api, FailingTenantApi)
    )
  end

  describe "ENV-A02 — view environment details" do
    @tag action: "ENV-A02"
    test "prod (multi-category, has a description) shows every field", %{conn: conn} do
      assert {:ok, view, _html} = live_environment(conn, "prod")

      assert has_element?(view, "#environment-detail")
      assert has_element?(view, "#environment-detail", "prod")
      assert has_element?(view, "#environment-description")
    end

    @tag action: "ENV-A02"
    test "the IRI is shown as text, with a copy button and a validated open-in-new-tab link",
         %{conn: conn} do
      assert {:ok, view, _html} = live_environment(conn, "prod")

      html = view |> element("#environment-detail") |> render()
      doc = LazyHTML.from_fragment(html)

      refute Enum.empty?(LazyHTML.query(doc, "[id=\"copy-iri\"]"))
      assert LazyHTML.text(doc) =~ "https://tenant.example.com/environment/prod"

      open_iri = LazyHTML.query(doc, "[id=\"open-iri\"]")
      refute Enum.empty?(open_iri)

      assert LazyHTML.attribute(open_iri, "href") == [
               "https://tenant.example.com/environment/prod"
             ]

      assert LazyHTML.attribute(open_iri, "target") == ["_blank"]
      assert LazyHTML.attribute(open_iri, "rel") == ["noopener noreferrer"]
    end

    @tag action: "ENV-A02"
    test "an iri with an unsafe scheme renders as text with no open-in-new-tab link", %{
      conn: conn
    } do
      seed_environment(%{"shortName" => "mailto-env", "iri" => "mailto:ops@example.com"})

      assert {:ok, view, _html} = live_environment(conn, "mailto-env")

      html = view |> element("#environment-detail") |> render()
      doc = LazyHTML.from_fragment(html)

      refute Enum.empty?(LazyHTML.query(doc, "[id=\"copy-iri\"]"))
      assert Enum.empty?(LazyHTML.query(doc, "[id=\"open-iri\"]"))
      assert LazyHTML.text(doc) =~ "mailto:ops@example.com"
    end

    @tag action: "ENV-A02"
    test "sandbox (no description) omits the description row entirely", %{conn: conn} do
      assert {:ok, view, _html} = live_environment(conn, "sandbox")

      assert has_element?(view, "#environment-detail")
      refute has_element?(view, "#environment-description")
    end

    @tag action: "ENV-A02"
    test "dev (no categories) renders \"None\" without breaking the layout", %{conn: conn} do
      assert {:ok, view, _html} = live_environment(conn, "dev")

      assert has_element?(view, "#environment-detail")
      assert has_element?(view, "#environment-detail", "None")
    end
  end

  describe "ENV-A03 — distinguish active from archived environments" do
    @tag action: "ENV-A03"
    test "an active environment is badged Active", %{conn: conn} do
      assert {:ok, view, _html} = live_environment(conn, "prod")

      assert has_element?(view, "#environment-detail .badge", "Active")
      refute has_element?(view, "#environment-detail .badge", "Archived")
    end

    @tag action: "ENV-A03"
    test "legacy-qa is badged Archived", %{conn: conn} do
      assert {:ok, view, _html} = live_environment(conn, "legacy-qa")

      assert has_element?(view, "#environment-detail .badge", "Archived")
      refute has_element?(view, "#environment-detail .badge", "Active")
    end
  end

  describe "ENV-A04 — navigate from an environment to its secrets" do
    @tag action: "ENV-A04"
    test "#manage-secrets-link navigates to that environment's secrets view", %{conn: conn} do
      assert {:ok, view, _html} = live_environment(conn, "prod")

      assert has_element?(view, "#manage-secrets-link")

      assert {:ok, secrets_view, _html} =
               view
               |> element("#manage-secrets-link")
               |> render_click()
               |> follow_redirect(conn, ~p"/environments/prod/secrets")

      assert has_element?(secrets_view, "#tenant-identifier")
    end
  end

  describe "ENV-A05 — handle an unknown or mistyped environment" do
    @tag action: "ENV-A05"
    test "an unknown short name renders not-found, not a crash, not unavailable", %{conn: conn} do
      assert {:ok, view, _html} = live_environment(conn, "nope")

      assert has_element?(view, "#environment-not-found")
      refute has_element?(view, "#environment-unavailable")
      refute has_element?(view, "#environment-detail")
    end
  end

  describe "ENV-A06 — archived environments are reachable directly" do
    @tag action: "ENV-A06"
    test "legacy-qa is reachable by direct URL, renders detail badged Archived, and its manage-secrets link works",
         %{conn: conn} do
      assert {:ok, view, _html} = live_environment(conn, "legacy-qa")

      assert has_element?(view, "#environment-detail")
      assert has_element?(view, "#environment-detail .badge", "Archived")

      assert {:ok, secrets_view, _html} =
               view
               |> element("#manage-secrets-link")
               |> render_click()
               |> follow_redirect(conn, ~p"/environments/legacy-qa/secrets")

      assert has_element?(secrets_view, "#tenant-identifier")
    end
  end

  describe "ENV-A07 — environments view is read-only" do
    @tag action: "ENV-A07"
    test "no form, no write phx-click, no delete affordance anywhere in the detail view", %{
      conn: conn
    } do
      assert {:ok, view, _html} = live_environment(conn, "prod")

      html = view |> element("#environment-detail") |> render()
      doc = LazyHTML.from_fragment(html)

      assert Enum.empty?(LazyHTML.query(doc, "form"))
      assert Enum.empty?(LazyHTML.query(doc, "[phx-click]"))
      assert Enum.empty?(LazyHTML.query(doc, "[phx-submit]"))
      refute html =~ ~r/delete/i
      refute html =~ ~r/>\s*edit\s*</i
      refute html =~ ~r/>\s*create\s*</i
    end
  end

  describe "an invalid environment name" do
    test "renders environment-invalid, mirroring SEC-A15's test", %{conn: conn} do
      assert {:ok, view, _html} = live(conn, "/environments/..%2f..%2fetc")

      assert has_element?(view, "#environment-invalid")
      refute has_element?(view, "#environment-detail")
    end
  end

  describe "the unavailable state is distinct from not-found" do
    test "a swapped-module tenant_api failure renders environment-unavailable", %{conn: conn} do
      use_failing_tenant_api(:unavailable)

      assert {:ok, view, _html} = live_environment(conn, "prod")

      assert has_element?(view, "#environment-unavailable")
      refute has_element?(view, "#environment-not-found")
      refute has_element?(view, "#environment-detail")
    end
  end

  describe "every Nucleus.Backend.Error kind renders a state, never crashes" do
    test "the shell stays intact and live/2 never returns an error tuple, for every kind", %{
      conn: conn
    } do
      for kind <- Error.kinds() do
        use_failing_tenant_api(kind)

        assert {:ok, view, _html} = live_environment(conn, "prod"),
               "expected live/2 to succeed for kind #{inspect(kind)}"

        assert has_element?(view, "#tenant-identifier")
        refute has_element?(view, "#environment-detail")
      end
    end
  end

  describe "accent color and IRI are never interpolated raw" do
    test "a malicious iri and accent_color render as escaped text, never as href or unescaped style",
         %{conn: conn} do
      seed_environment(%{
        "shortName" => "malicious-env",
        "iri" => "javascript:alert(1)",
        "accentColor" => "red;}</style><script>"
      })

      assert {:ok, view, _html} = live_environment(conn, "malicious-env")

      assert has_element?(view, "#environment-detail")

      html = view |> element("#environment-detail") |> render()
      doc = LazyHTML.from_fragment(html)

      # Never an href, and no open-in-new-tab link is rendered at all.
      hrefs = doc |> LazyHTML.query("a[href]") |> LazyHTML.attribute("href")
      refute Enum.any?(hrefs, &(&1 =~ "javascript:"))
      assert Enum.empty?(LazyHTML.query(doc, "[id=\"open-iri\"]"))

      # Never interpolated unvalidated into a style attribute.
      styles = doc |> LazyHTML.query("[style]") |> LazyHTML.attribute("style")
      refute Enum.any?(styles, &(&1 =~ "red;}"))
      refute html =~ "</style><script>"

      # Falls back to a neutral swatch, and both raw values still show up as
      # escaped text.
      assert LazyHTML.text(doc) =~ "javascript:alert(1)"
      assert LazyHTML.text(doc) =~ "red;}</style><script>"
    end
  end
end
