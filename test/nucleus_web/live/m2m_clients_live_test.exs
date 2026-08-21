defmodule NucleusWeb.M2MClientsLiveTest do
  # Backend swap (`use_backend/1`) mutates node-global `:nucleus, :backends`
  # config, matching `Nucleus.M2MTest`'s own constraint — `async: false`.
  use NucleusWeb.LiveCase, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.M2M.Client
  alias Nucleus.M2M.ClientName

  # Seeded in priv/backends/local_seed.json under TENANT_NAMESPACE = "local"
  # — the same fixtures `Nucleus.M2MTest` exercises at the context layer.
  @valid_client_id "4f2a9c1e7b3d8f0a1c2e3f4a5b6c7d8e"
  @valid_client_name "local-control-plane-OPS-1001-billing-sync"
  @valid_client_secret "b1c2d3e4f5a67890b1c2d3e4f5a67890b1c2d3e4f5a67890b1c2d3e4f5a6789"
  @denied_client_id "5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e"
  @denied_client_name "local-control-plane-OPS-1042-nucleus"
  @out_of_tenant_client_id "6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f"
  @out_of_tenant_client_name "acme-control-plane-OPS-1043-sync"

  @degraded_client_id "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  defmodule EmptyM2MClients do
    @moduledoc "M2M-A02's empty-tenant fixture — see `Nucleus.M2MTest`'s twin."
    @behaviour Nucleus.M2M.Clients

    @impl Nucleus.M2M.Clients
    def list_clients, do: {:ok, []}

    @impl Nucleus.M2M.Clients
    def describe_client(_client_id), do: raise("should not be called")

    @impl Nucleus.M2M.Clients
    def create_client(_client_name, _settings), do: raise("should not be called")

    @impl Nucleus.M2M.Clients
    def rotate_secret(_client_id), do: raise("should not be called")

    @impl Nucleus.M2M.Clients
    def health_check, do: raise("should not be called")
  end

  defmodule FailingM2MClients do
    @moduledoc """
    A controllable `list_clients/0` failure — a swapped module, not
    `LOCAL_FORCE_ERROR`, for the same node-global reason `Nucleus.M2MTest`'s
    twin documents.
    """
    @behaviour Nucleus.M2M.Clients

    @impl Nucleus.M2M.Clients
    def list_clients do
      kind = Application.get_env(:nucleus, __MODULE__, :unavailable)
      {:error, Error.new(kind, :m2m, "forced for test", %{})}
    end

    @impl Nucleus.M2M.Clients
    def describe_client(_client_id), do: raise("should not be called")

    @impl Nucleus.M2M.Clients
    def create_client(_client_name, _settings), do: raise("should not be called")

    @impl Nucleus.M2M.Clients
    def rotate_secret(_client_id), do: raise("should not be called")

    @impl Nucleus.M2M.Clients
    def health_check, do: raise("should not be called")
  end

  defmodule DegradedRowM2MClients do
    @moduledoc "EN-10 / #33's Decision 6 fixture — see `Nucleus.M2MTest`'s twin."
    @behaviour Nucleus.M2M.Clients

    @impl Nucleus.M2M.Clients
    def list_clients do
      {:ok,
       [
         %Client{
           client_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
           client_name: "local-control-plane-OPS-9999-degraded",
           created_date: nil,
           created_date_error: :unavailable
         }
       ]}
    end

    @impl Nucleus.M2M.Clients
    def describe_client(_client_id), do: raise("should not be called")

    @impl Nucleus.M2M.Clients
    def create_client(_client_name, _settings), do: raise("should not be called")

    @impl Nucleus.M2M.Clients
    def rotate_secret(_client_id), do: raise("should not be called")

    @impl Nucleus.M2M.Clients
    def health_check, do: raise("should not be called")
  end

  defp use_backend(module) do
    original = Application.get_env(:nucleus, :backends, [])
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)
    Application.put_env(:nucleus, :backends, Keyword.put(original, :m2m, module))
  end

  defp row_client_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#m2m-clients-table-body [data-client-id]")
    |> LazyHTML.attribute("data-client-id")
  end

  describe "M2M-A01 — list the tenant's M2M clients" do
    @tag action: "M2M-A01"
    test "shows every visible client with its name, ID and creation date", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      assert has_element?(view, "#m2m-clients-table")

      assert has_element?(
               view,
               ~s(#m2m-clients-table-body [data-client-id="#{@valid_client_id}"])
             )

      assert has_element?(view, "#m2m-clients-table-body", @valid_client_name)
      assert has_element?(view, "#m2m-clients-table-body", @valid_client_id)
    end

    @tag action: "M2M-A01"
    test "a client with created_date_error set renders the date-unavailable state, not a crash",
         %{conn: conn} do
      use_backend(DegradedRowM2MClients)

      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      assert has_element?(view, "#m2m-client-date-unavailable-#{@degraded_client_id}")
    end

    @tag action: "M2M-A01"
    test "the deny-listed client's name and ID appear nowhere in the rendered HTML", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/m2m/clients")

      refute html =~ @denied_client_name
      refute html =~ @denied_client_id
    end

    @tag action: "M2M-A01"
    test "the out-of-tenant client's name and ID appear nowhere in the rendered HTML", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/m2m/clients")

      refute html =~ @out_of_tenant_client_name
      refute html =~ @out_of_tenant_client_id
    end

    @tag action: "M2M-A01"
    test "no reveal control, no masked-secret column, and no secret value anywhere in the DOM",
         %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/m2m/clients")

      refute html =~ @valid_client_secret
      refute has_element?(view, "th", "Secret")
      refute has_element?(view, "[phx-click=\"reveal\"]")
    end

    @tag action: "M2M-A01"
    test "row order is stable across two mounts", %{conn: conn} do
      {:ok, view1, _html} = live(conn, ~p"/m2m/clients")
      {:ok, view2, _html} = live(conn, ~p"/m2m/clients")

      ids1 = row_client_ids(view1)
      ids2 = row_client_ids(view2)

      assert ids1 != []
      assert ids1 == ids2
    end
  end

  describe "M2M-A02 — empty state" do
    @tag action: "M2M-A02"
    test "with an empty seed section, #m2m-clients-empty renders and #m2m-clients-table does not",
         %{conn: conn} do
      use_backend(EmptyM2MClients)

      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      assert has_element?(view, "#m2m-clients-empty")
      refute has_element?(view, "#m2m-clients-table")
    end

    @tag action: "M2M-A02"
    test "#new-m2m-client-button is present in the empty state", %{conn: conn} do
      use_backend(EmptyM2MClients)

      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      assert has_element?(view, "#new-m2m-client-button")
    end

    @tag action: "M2M-A02"
    test "#new-m2m-client-button is also present in the populated state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      assert has_element?(view, "#new-m2m-client-button")
    end
  end

  describe "error states" do
    @error_state_ids %{
      not_configured: "m2m-clients-misconfigured",
      unavailable: "m2m-clients-unavailable",
      auth_expired: "m2m-clients-auth-expired"
    }

    for {kind, expected_id} <- @error_state_ids do
      @tag kind: kind
      @tag expected_id: expected_id
      test "#{kind} renders its own state, mutually exclusive, shell intact, no client UI", %{
        conn: conn,
        kind: kind,
        expected_id: expected_id
      } do
        use_backend(FailingM2MClients)
        Application.put_env(:nucleus, FailingM2MClients, kind)

        {:ok, view, _html} = live(conn, ~p"/m2m/clients")

        assert has_element?(view, "##{expected_id}")

        for other_id <- Map.values(@error_state_ids) -- [expected_id] do
          refute has_element?(view, "##{other_id}")
        end

        refute has_element?(view, "#m2m-clients-table")
        refute has_element?(view, "#m2m-clients-empty")
        refute has_element?(view, "#new-m2m-client-button")
        # The shell survives every error kind (NAV-A07's equivalent for M2M).
        assert has_element?(view, "#tenant-identifier")
      end
    end

    test "live/2 returns {:ok, ...} for every error kind — the LiveView never crashes", %{
      conn: conn
    } do
      for kind <- Error.kinds() do
        use_backend(FailingM2MClients)
        Application.put_env(:nucleus, FailingM2MClients, kind)

        assert {:ok, _view, _html} = live(conn, ~p"/m2m/clients")
      end
    end
  end

  describe "M2M-A04 — start creating a new client" do
    @tag action: "M2M-A04"
    test "opens a form prompting for ticket ID and purpose", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      view |> element("#new-m2m-client-button") |> render_click()

      assert has_element?(view, "#new-m2m-client-modal")
      assert has_element?(view, "#new-m2m-client-form")
      assert has_element?(view, "#new-m2m-client-ticket-id")
      assert has_element?(view, "#new-m2m-client-purpose")
    end

    @tag action: "M2M-A04"
    test "also opens from the empty state's button", %{conn: conn} do
      use_backend(EmptyM2MClients)
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      view |> element("#new-m2m-client-button") |> render_click()

      assert has_element?(view, "#new-m2m-client-form")
      assert has_element?(view, "#new-m2m-client-ticket-id")
      assert has_element?(view, "#new-m2m-client-purpose")
    end

    @tag action: "M2M-A04"
    test "the access token validity input is pre-filled with the default of 15", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      html = view |> element("#new-m2m-client-button") |> render_click()

      assert has_element?(view, "#new-m2m-client-token-validity")
      assert html =~ ~s(value="15")
    end
  end

  describe "M2M-A05 — validate the ticket ID" do
    @tag action: "M2M-A05"
    test "the wrong case shows a format-specific message and blocks submission", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      html =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => "ops-1234", "purpose" => "sync"}
        )
        |> render_change()

      assert html =~ "uppercase letters, a hyphen, then digits"
      assert has_element?(view, "#new-m2m-client-submit[disabled]")
    end

    @tag action: "M2M-A05"
    test "a 21-character ticket ID shows a length-specific message, distinct from the format one",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      too_long = "OPS-" <> String.duplicate("1", 17)

      html =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => too_long, "purpose" => "sync"}
        )
        |> render_change()

      assert html =~ "20 characters or fewer"
      refute html =~ "uppercase letters, a hyphen, then digits"
      assert has_element?(view, "#new-m2m-client-submit[disabled]")
    end

    @tag action: "M2M-A05"
    test "the submit button starts disabled on the freshly-opened, empty form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      assert has_element?(view, "#new-m2m-client-submit[disabled]")
    end
  end

  describe "M2M-A06 — validate the purpose" do
    @tag action: "M2M-A06"
    test "a leading hyphen shows a message distinct from a charset violation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      leading_html =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => "OPS-1234", "purpose" => "-sync"}
        )
        |> render_change()

      charset_html =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => "OPS-1234", "purpose" => "Nightly Sync"}
        )
        |> render_change()

      assert leading_html =~ "cannot start with a hyphen"
      assert charset_html =~ "lowercase letters, digits, and hyphens"
      refute leading_html =~ "lowercase letters, digits, and hyphens"
      refute charset_html =~ "cannot start with a hyphen"
      assert has_element?(view, "#new-m2m-client-submit[disabled]")
    end
  end

  describe "M2M-A07 — preview the resulting client name before creating" do
    @tag action: "M2M-A07"
    test "with both fields valid, the preview renders exactly ClientName.build/2's output", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      expected = ClientName.build("OPS-4242", "nightly-sync")

      html =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => "OPS-4242", "purpose" => "nightly-sync"}
        )
        |> render_change()

      assert has_element?(view, "#new-m2m-client-name-preview", expected)
      assert html =~ expected
    end

    @tag action: "M2M-A07"
    test "the preview updates as input changes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      first =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => "OPS-1", "purpose" => "sync-one"}
        )
        |> render_change()

      second =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => "OPS-2", "purpose" => "sync-two"}
        )
        |> render_change()

      assert first =~ ClientName.build("OPS-1", "sync-one")
      assert second =~ ClientName.build("OPS-2", "sync-two")
      refute first == second
    end

    @tag action: "M2M-A07"
    test "with only one field filled, no name is previewed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      html =
        view
        |> form("#new-m2m-client-form", new_client: %{"ticket_id" => "OPS-1234", "purpose" => ""})
        |> render_change()

      refute html =~ "control-plane-OPS-1234"

      assert has_element?(
               view,
               "#new-m2m-client-name-preview",
               "Enter a ticket ID and purpose to preview the client name."
             )
    end

    @tag action: "M2M-A07"
    test "with a field invalid, no name is previewed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      html =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => "ops-1234", "purpose" => "sync"}
        )
        |> render_change()

      refute html =~ "control-plane-ops-1234"
      refute html =~ "control-plane-OPS-1234"

      assert has_element?(
               view,
               "#new-m2m-client-name-preview",
               "Enter a ticket ID and purpose to preview the client name."
             )
    end

    @tag action: "M2M-A07"
    test "changing TENANT_NAMESPACE config changes the preview", %{conn: conn} do
      original = Application.get_env(:nucleus, Nucleus.Scope, [])
      on_exit(fn -> Application.put_env(:nucleus, Nucleus.Scope, original) end)

      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      form_params = %{"ticket_id" => "OPS-1234", "purpose" => "nightly-sync"}

      local_html =
        view
        |> form("#new-m2m-client-form", new_client: form_params)
        |> render_change()

      Application.put_env(:nucleus, Nucleus.Scope, tenant_namespace: "acme")

      acme_html =
        view
        |> form("#new-m2m-client-form", new_client: form_params)
        |> render_change()

      assert local_html =~ "local-control-plane-OPS-1234-nightly-sync"
      assert acme_html =~ "acme-control-plane-OPS-1234-nightly-sync"
      refute local_html == acme_html
    end
  end

  describe "dismissal — cancel, Escape and backdrop all reach cancel_new_client" do
    @tag action: "M2M-A04"
    test "cancel closes the modal and creates nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      view |> element("#new-m2m-client-button") |> render_click()
      assert has_element?(view, "#new-m2m-client-modal")

      view
      |> form("#new-m2m-client-form",
        new_client: %{"ticket_id" => "OPS-1234", "purpose" => "not-saved"}
      )
      |> render_change()

      view |> element("#new-m2m-client-cancel") |> render_click()

      refute has_element?(view, "#new-m2m-client-modal")
      refute has_element?(view, "#m2m-clients-table-body", "not-saved")
    end

    test "the modal's Escape wiring is present and reaches cancel_new_client", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      view |> element("#new-m2m-client-button") |> render_click()
      doc = view |> render() |> LazyHTML.from_fragment()

      assert [cancel] =
               doc |> LazyHTML.query("#new-m2m-client-modal") |> LazyHTML.attribute("data-cancel")

      assert cancel =~ "cancel_new_client"

      container = LazyHTML.query(doc, "#new-m2m-client-modal-container")
      assert LazyHTML.attribute(container, "phx-key") == ["escape"]
      assert LazyHTML.attribute(container, "phx-window-keydown") != []
    end

    test "backdrop dismissal reaches cancel_new_client", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      view |> element("#new-m2m-client-button") |> render_click()
      doc = view |> render() |> LazyHTML.from_fragment()

      container = LazyHTML.query(doc, "#new-m2m-client-modal-container")
      assert LazyHTML.attribute(container, "phx-click-away") != []

      assert [cancel] =
               doc |> LazyHTML.query("#new-m2m-client-modal") |> LazyHTML.attribute("data-cancel")

      assert cancel =~ "cancel_new_client"
    end

    test "reopening after a cancelled attempt shows an empty form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      view |> element("#new-m2m-client-button") |> render_click()

      view
      |> form("#new-m2m-client-form",
        new_client: %{"ticket_id" => "OPS-9999", "purpose" => "discarded"}
      )
      |> render_change()

      view |> element("#new-m2m-client-cancel") |> render_click()

      html = view |> element("#new-m2m-client-button") |> render_click()

      refute html =~ "OPS-9999"
      refute html =~ "discarded"
    end
  end

  describe "submitting while save_new_client is unimplemented" do
    test "does not crash the LiveView", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      html =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => "OPS-1234", "purpose" => "nightly-sync"}
        )
        |> render_submit()

      assert html =~ "M2M Clients"
    end

    test "dispatching save_new_client directly (bypassing the disabled button) does not crash",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      html = render_click(view, "save_new_client", %{})

      assert html =~ "M2M Clients"
    end
  end

  defmodule NewClientModalBrowserGaps do
    @moduledoc """
    `M2M-A04`–`A07` dismissal behaviour `Phoenix.LiveViewTest` structurally
    cannot execute — the same gap recorded for `SEC-A13` in
    `NucleusWeb.SecretsLiveTest.NewSecretModalBrowserGaps` and
    `test/README.md`: Escape and a backdrop click reach the server only by
    running the `Phoenix.LiveView.JS` chain in `data-cancel`, which needs a
    real key event, a real click outside the `.modal-box`, and a client to
    interpret the command list (`docs/adr/0008-test-strategy.md`). Focus
    restoration is the same story — `JS.push_focus/1`/`JS.pop_focus/1` are
    client-side.

    The describe block above proves the wiring these gaps depend on
    (`data-cancel` present and pushing `cancel_new_client`, `phx-key="escape"`,
    `phx-window-keydown`, `phx-click-away` all present) and proves the one
    route a `render_click/1` can actually drive (the Cancel button) discards
    cleanly. None of `M2M-A04`–`A07` depends on real Escape keypresses, the
    focus trap, or focus restoration, so no action tag is weakened by this
    gap — but it is noted here rather than left for a reader to assume the
    dismissal tests prove more than they do.

    Skipped unconditionally rather than by default-exclude tag, matching
    `NewSecretModalBrowserGaps`'s reasoning exactly.
    """

    use ExUnit.Case, async: true

    @moduletag :browser
    @moduletag skip: "no browser driver in this repo — see docs/adr/0008-test-strategy.md"

    test "pressing Escape while the modal is open closes it and creates nothing" do
    end

    test "clicking the backdrop outside the modal box closes it and creates nothing" do
    end

    test "focus moves into the modal on open and returns to #new-m2m-client-button on dismissal" do
    end

    test "Tab is trapped inside the modal while it is open" do
    end

    test "the preview updates smoothly while typing, with no visible lag or flicker" do
    end
  end

  describe "navigation to Show" do
    test "a row's view link navigates to /m2m/clients/:client_id and Show's stub mounts without crashing",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      assert {:ok, show_view, _html} =
               view
               |> element("#view-client-#{@valid_client_id}")
               |> render_click()
               |> follow_redirect(conn, ~p"/m2m/clients/#{@valid_client_id}")

      assert has_element?(show_view, "#m2m-client-detail-placeholder")
    end
  end
end
