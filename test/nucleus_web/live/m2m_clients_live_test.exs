defmodule NucleusWeb.M2MClientsLiveTest do
  # Backend swap (`use_backend/1`) mutates node-global `:nucleus, :backends`
  # config, matching `Nucleus.M2MTest`'s own constraint — `async: false`.
  use NucleusWeb.LiveCase, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Seed
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
    A controllable `list_clients/0`/`describe_client/1` failure — a swapped
    module, not `LOCAL_FORCE_ERROR`, for the same node-global reason
    `Nucleus.M2MTest`'s twin documents. `describe_client/1` is `Show`'s call
    path (M2M-S3); `list_clients/0` remains `Index`'s.
    """
    @behaviour Nucleus.M2M.Clients

    @impl Nucleus.M2M.Clients
    def list_clients do
      kind = Application.get_env(:nucleus, __MODULE__, :unavailable)
      {:error, Error.new(kind, :m2m, "forced for test", %{})}
    end

    @impl Nucleus.M2M.Clients
    def describe_client(_client_id) do
      kind = Application.get_env(:nucleus, __MODULE__, :unavailable)
      {:error, Error.new(kind, :m2m, "forced for test", %{})}
    end

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

  defmodule FailingCreateM2MClients do
    @moduledoc """
    A controllable `create_client/2` failure, for M2M-S5's `save_new_client`
    failure-kind coverage. `list_clients/0` and `describe_client/1` delegate
    to `Nucleus.M2M.Clients.Local` so `Index`'s own list still renders
    normally — only creation itself is forced to fail, with a fresh kind per
    test via `Application.put_env/3`, matching `FailingM2MClients`'s
    convention one callback over.
    """
    @behaviour Nucleus.M2M.Clients

    @impl Nucleus.M2M.Clients
    def list_clients, do: Nucleus.M2M.Clients.Local.list_clients()

    @impl Nucleus.M2M.Clients
    def describe_client(client_id), do: Nucleus.M2M.Clients.Local.describe_client(client_id)

    @impl Nucleus.M2M.Clients
    def create_client(_client_name, _settings) do
      kind = Application.get_env(:nucleus, __MODULE__, :unavailable)
      {:error, Error.new(kind, :m2m, "forced for test", %{})}
    end

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

  # The full, untruncated client ID and secret text as rendered inside the
  # credentials panel — `M2M-A08`'s "shown exactly once" is checked against
  # this, not against a value the test already knows ahead of time (the
  # secret is generated fresh, server-side, on every create).
  defp credentials_panel_values(view) do
    doc = view |> render() |> LazyHTML.from_fragment()

    client_id =
      doc |> LazyHTML.query("#m2m-new-client-id") |> LazyHTML.text() |> String.trim()

    client_secret =
      doc |> LazyHTML.query("#m2m-new-client-secret") |> LazyHTML.text() |> String.trim()

    {client_id, client_secret}
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

  describe "M2M-A08 — create a client" do
    @tag action: "M2M-A08"
    test "submitting a valid form closes the modal and renders #m2m-client-credentials containing both the ID and the secret",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      view
      |> form("#new-m2m-client-form",
        new_client: %{"ticket_id" => "OPS-7001", "purpose" => "first-client"}
      )
      |> render_submit()

      refute has_element?(view, "#new-m2m-client-modal")
      assert has_element?(view, "#m2m-client-credentials")

      {client_id, client_secret} = credentials_panel_values(view)
      assert client_id != ""
      assert client_secret != ""
    end

    @tag action: "M2M-A08"
    test "#m2m-client-credentials-warning is present and states the secret will not be shown again",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      view
      |> form("#new-m2m-client-form",
        new_client: %{"ticket_id" => "OPS-7002", "purpose" => "warning-check"}
      )
      |> render_submit()

      assert has_element?(view, "#m2m-client-credentials-warning", "will not be shown again")
    end

    @tag action: "M2M-A08"
    test "the row appears in the list, in the correct sort position", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      # Sorting is by the full `client_name` string, and `ticket_id` sits
      # before `purpose` in it (`{tenant}-control-plane-{ticket_id}-{purpose}`)
      # — every seeded fixture's ticket ID starts "OPS-1"/"OPS-9", so
      # "OPS-0001" sorts first regardless of purpose.
      view
      |> form("#new-m2m-client-form",
        new_client: %{"ticket_id" => "OPS-0001", "purpose" => "sorts-first"}
      )
      |> render_submit()

      {client_id, _secret} = credentials_panel_values(view)

      assert [^client_id | _rest] = row_client_ids(view)
    end

    @tag action: "M2M-A08"
    test "creating the first client replaces #m2m-clients-empty with #m2m-clients-table", %{
      conn: conn
    } do
      Seed.write(:m2m, %{})

      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      assert has_element?(view, "#m2m-clients-empty")

      view |> element("#new-m2m-client-button") |> render_click()

      view
      |> form("#new-m2m-client-form",
        new_client: %{"ticket_id" => "OPS-7004", "purpose" => "very-first"}
      )
      |> render_submit()

      refute has_element?(view, "#m2m-clients-empty")
      assert has_element?(view, "#m2m-clients-table")
    end

    @tag action: "M2M-A08"
    test "copy affordances are present for both values, each carrying the full untruncated value",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      view
      |> form("#new-m2m-client-form",
        new_client: %{"ticket_id" => "OPS-7005", "purpose" => "copy-check"}
      )
      |> render_submit()

      {client_id, client_secret} = credentials_panel_values(view)
      doc = view |> render() |> LazyHTML.from_fragment()

      assert LazyHTML.query(doc, "#copy-m2m-client-id") |> LazyHTML.attribute("data-value") ==
               [client_id]

      assert LazyHTML.query(doc, "#copy-m2m-client-secret") |> LazyHTML.attribute("data-value") ==
               [client_secret]
    end

    @tag action: "M2M-A08"
    test "the panel does not close on an unrelated event; only the explicit dismiss control closes it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      view
      |> form("#new-m2m-client-form",
        new_client: %{"ticket_id" => "OPS-7006", "purpose" => "stays-open"}
      )
      |> render_submit()

      assert has_element?(view, "#m2m-client-credentials")

      # An unrelated event — retrying the list, say — must not touch the panel.
      render_click(view, "retry", %{})
      assert has_element?(view, "#m2m-client-credentials")

      view |> element("#m2m-client-credentials-dismiss") |> render_click()
      refute has_element?(view, "#m2m-client-credentials")
    end

    @tag action: "M2M-A08"
    test "after dismissal, the secret is gone from the rendered HTML and from the socket assigns",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      view
      |> form("#new-m2m-client-form",
        new_client: %{"ticket_id" => "OPS-7007", "purpose" => "dismiss-check"}
      )
      |> render_submit()

      {_client_id, client_secret} = credentials_panel_values(view)

      html = view |> element("#m2m-client-credentials-dismiss") |> render_click()

      refute html =~ client_secret
      refute has_element?(view, "#m2m-client-credentials")

      # Re-render, not just the click's own return value — this is what
      # makes "shown exactly once" true of socket state, not merely of one
      # HTML fragment.
      refute render(view) =~ client_secret
    end

    @tag action: "M2M-A08"
    test "the secret is in no flash message", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      html =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => "OPS-7008", "purpose" => "flash-check"}
        )
        |> render_submit()

      {_client_id, client_secret} = credentials_panel_values(view)
      refute has_element?(view, "[role='alert'][id^='flash']", client_secret)
      refute html =~ ~s(id="flash) <> "\"" <> client_secret
    end
  end

  describe "M2M-A18 — with a reserved purpose" do
    @tag action: "M2M-A18"
    test "the form stays open, the error names the reserved name, and no new row appears", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      ids_before = row_client_ids(view)

      html =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => "OPS-8001", "purpose" => "nucleus"}
        )
        |> render_submit()

      assert has_element?(view, "#new-m2m-client-modal")
      refute has_element?(view, "#m2m-client-credentials")
      assert html =~ "reserved for internal system use"
      assert row_client_ids(view) == ids_before
    end
  end

  describe "M2M-A05/A06 — direct event dispatch cannot bypass server-side validation" do
    @tag action: "M2M-A05"
    test "dispatching save_new_client directly with an invalid ticket ID creates nothing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      ids_before = row_client_ids(view)

      render_click(view, "save_new_client", %{
        "new_client" => %{"ticket_id" => "not-valid", "purpose" => "billing-sync"}
      })

      refute has_element?(view, "#m2m-client-credentials")
      assert row_client_ids(view) == ids_before
    end

    @tag action: "M2M-A06"
    test "dispatching save_new_client directly with an invalid purpose creates nothing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      ids_before = row_client_ids(view)

      render_click(view, "save_new_client", %{
        "new_client" => %{"ticket_id" => "OPS-8002", "purpose" => "Not Valid!"}
      })

      refute has_element?(view, "#m2m-client-credentials")
      assert row_client_ids(view) == ids_before
    end

    test "dispatching save_new_client with no new_client key at all does not crash", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      html = render_click(view, "save_new_client", %{})

      assert html =~ "M2M Clients"
    end
  end

  describe "failure handling — every Nucleus.Backend.Error kind" do
    @tag action: "M2M-A08"
    test "forced :unavailable shows an error, keeps the form open with input preserved, and retry succeeds without re-entry",
         %{conn: conn} do
      use_backend(FailingCreateM2MClients)
      Application.put_env(:nucleus, FailingCreateM2MClients, :unavailable)

      {:ok, view, _html} = live(conn, ~p"/m2m/clients")
      view |> element("#new-m2m-client-button") |> render_click()

      html =
        view
        |> form("#new-m2m-client-form",
          new_client: %{"ticket_id" => "OPS-8101", "purpose" => "retry-check"}
        )
        |> render_submit()

      assert html =~ "Can&#39;t create this client"
      assert has_element?(view, "#new-m2m-client-form")

      assert has_element?(view, "#new-m2m-client-ticket-id[value='OPS-8101']")
      assert has_element?(view, "#new-m2m-client-purpose[value='retry-check']")

      # Same form, no re-entry — swap the backend back and resubmit.
      use_backend(Nucleus.M2M.Clients.Local)

      view
      |> form("#new-m2m-client-form",
        new_client: %{"ticket_id" => "OPS-8101", "purpose" => "retry-check"}
      )
      |> render_submit()

      assert has_element?(view, "#m2m-client-credentials")
    end

    for kind <- Error.kinds() do
      @tag action: "M2M-A08"
      @tag kind: kind
      test "#{kind} renders without crashing the LiveView", %{conn: conn, kind: kind} do
        use_backend(FailingCreateM2MClients)
        Application.put_env(:nucleus, FailingCreateM2MClients, kind)

        {:ok, view, _html} = live(conn, ~p"/m2m/clients")
        view |> element("#new-m2m-client-button") |> render_click()

        html =
          view
          |> form("#new-m2m-client-form",
            new_client: %{"ticket_id" => "OPS-8102", "purpose" => "exhaustive-check"}
          )
          |> render_submit()

        assert html =~ "M2M Clients"
      end
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

  defmodule CredentialsPanelBrowserGaps do
    @moduledoc """
    `M2M-A08`'s "the user can copy both values" clause has a browser gap
    identical in shape to `SEC-A02`'s (`NucleusWeb.SecretsLiveTest.CopyButtonBrowserGaps`):
    `navigator.clipboard.writeText` needs a browser, so the actual clipboard
    write, its confirmation-face swap, the non-secure-context `execCommand`
    fallback, and a denied write's failure indication are all untestable
    here (`docs/adr/0008-test-strategy.md`).

    Stated explicitly, per the ticket's own instruction, rather than left
    for a reader to assume the describe block above proves more than it
    does: `M2M-A08` is still legitimately claimed on that block, because its
    `Then` clauses are "shown exactly once", "with a clear warning", and the
    user *can* copy — the affordance's presence and its exact, untruncated
    `data-value` are what is actually proven (`credentials_panel_values/1`,
    `#copy-m2m-client-id`/`#copy-m2m-client-secret`'s `data-value`
    attributes). Only the browser's clipboard write itself is not.

    This panel's own dismiss-only design (no `phx-click-away`, no
    `phx-window-keydown` — see `NucleusWeb.M2MClientsLive.CredentialsPanel`'s
    moduledoc) means it carries none of `NewClientModalBrowserGaps`'
    Escape/backdrop gaps: there is no Escape or backdrop wiring on this
    panel to be a gap in.

    Skipped unconditionally, matching every other browser-gap module in this
    suite.
    """

    use ExUnit.Case, async: true

    @moduletag :browser
    @moduletag skip: "no browser driver in this repo — see docs/adr/0008-test-strategy.md"

    test "navigator.clipboard.writeText is called with the client ID's full, untruncated value" do
    end

    test "navigator.clipboard.writeText is called with the secret's full, untruncated value" do
    end

    test "on success, each copy button's icon swaps to a check and reverts after ~2s" do
    end

    test "over a non-secure context (no navigator.clipboard), the execCommand fallback copies" do
    end

    test "a failed copy (permission denied, unfocused document) shows failure, never success" do
    end

    test "focus moves into the panel on open and returns to #new-m2m-client-button on dismissal" do
    end

    test "Tab is trapped inside the panel while it is open" do
    end
  end

  describe "navigation to Show" do
    test "a row's view link navigates to /m2m/clients/:client_id and Show renders the client's detail",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      assert {:ok, show_view, _html} =
               view
               |> element("#view-client-#{@valid_client_id}")
               |> render_click()
               |> follow_redirect(conn, ~p"/m2m/clients/#{@valid_client_id}")

      assert has_element?(show_view, "#m2m-client-detail")
      assert has_element?(show_view, "#m2m-client-id", @valid_client_id)
    end
  end

  describe "M2M-A03 — view a client's details" do
    @tag action: "M2M-A03"
    test "shows ID, name, scope, validity and creation date, and never the secret", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/m2m/clients/#{@valid_client_id}")

      assert has_element?(view, "#m2m-client-detail")
      assert has_element?(view, "#m2m-client-secret-note")
      refute html =~ @valid_client_secret
    end

    @tag action: "M2M-A03"
    test "all five fields render with their DOM ids", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients/#{@valid_client_id}")

      assert has_element?(view, "#m2m-client-id", @valid_client_id)
      assert has_element?(view, "#m2m-client-name", @valid_client_name)
      assert has_element?(view, "#m2m-client-scope")
      assert has_element?(view, "#m2m-client-token-validity")
      assert has_element?(view, "#m2m-client-created")
    end

    @tag action: "M2M-A03"
    test "#m2m-client-secret-note is present and each seeded client's secret appears nowhere in its own rendered HTML",
         %{conn: conn} do
      # Every seeded, in-tenant, non-denied client — not just @valid_client_id —
      # per the acceptance criterion "for every seeded client", not just one.
      visible_fixtures = [
        {@valid_client_id, @valid_client_secret},
        {"7a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d",
         "c2d3e4f5a67890b1c2d3e4f5a67890b1c2d3e4f5a67890b1c2d3e4f5a67890b"},
        {"9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a",
         "d3e4f5a67890b1c2d3e4f5a67890b1c2d3e4f5a67890b1c2d3e4f5a67890b1c"},
        {"1c2d3e4f5a67890b1c2d3e4f5a67890b",
         "e4f5a67890b1c2d3e4f5a67890b1c2d3e4f5a67890b1c2d3e4f5a67890b1c2d"},
        {"2e3f4a5b6c7d8e9f0a1b2c3d4e5f6a7b",
         "f5a67890b1c2d3e4f5a67890b1c2d3e4f5a67890b1c2d3e4f5a67890b1c2d3e"}
      ]

      for {client_id, secret} <- visible_fixtures do
        {:ok, view, html} = live(conn, ~p"/m2m/clients/#{client_id}")

        assert has_element?(view, "#m2m-client-detail")
        assert has_element?(view, "#m2m-client-secret-note")
        refute html =~ secret
      end
    end

    @tag action: "M2M-A03"
    test "one m2m_client_viewed per open; a subsequent unrelated event on the same view emits no second one",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients/#{@valid_client_id}")

      assert_audit_event(:m2m_client_viewed, details: %{client_name: @valid_client_name})

      # `Show` defines no `handle_event/3` or `handle_info/2` of its own (only
      # secret rotation, M2M-S6, will add one) — there is no genuine
      # "unrelated event" to dispatch at this LiveView yet. `render/1` is the
      # closest available proxy: forcing a re-render without a fresh mount
      # must not re-invoke `view/2`, since the audit call lives in `mount/3`,
      # not `render/1`.
      render(view)

      count_viewed = fn -> audit_events() |> Enum.count(&(&1.event == :m2m_client_viewed)) end
      assert count_viewed.() == 1

      # The stronger, concretely testable half of "once per open": a second,
      # independent open of the *same* client — a reload, or a second tab —
      # is its own event, not folded into or blocked by the first. Proves
      # `view/2` neither under- nor over-counts across separate mounts.
      {:ok, _second_view, _html} = live(conn, ~p"/m2m/clients/#{@valid_client_id}")
      assert count_viewed.() == 2
    end
  end

  describe "M2M-A13 — invalid client ID" do
    @tag action: "M2M-A13"
    test "a malformed ID in the URL renders #m2m-client-invalid-id, no #m2m-client-detail", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients/not a valid id")

      assert has_element?(view, "#m2m-client-invalid-id")
      refute has_element?(view, "#m2m-client-detail")
    end
  end

  describe "M2M-A14 — not found, identical for deny-listed and nonexistent" do
    @tag action: "M2M-A14"
    test "the seeded deny-listed client's ID renders #m2m-client-not-found, identical to a genuinely nonexistent ID",
         %{conn: conn} do
      {:ok, denied_view, _html} = live(conn, ~p"/m2m/clients/#{@denied_client_id}")
      {:ok, nonexistent_view, _html} = live(conn, ~p"/m2m/clients/#{String.duplicate("f", 32)}")

      assert has_element?(denied_view, "#m2m-client-not-found")
      refute has_element?(denied_view, "#m2m-client-detail")

      assert has_element?(nonexistent_view, "#m2m-client-not-found")
      refute has_element?(nonexistent_view, "#m2m-client-detail")
    end

    @tag action: "M2M-A14"
    test "the out-of-tenant client's ID also renders #m2m-client-not-found", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients/#{@out_of_tenant_client_id}")

      assert has_element?(view, "#m2m-client-not-found")
      refute has_element?(view, "#m2m-client-detail")
    end
  end

  describe "M2M-A15 — no update or delete affordance" do
    @tag action: "M2M-A15"
    test "no rename, edit, reconfigure or delete control exists in #m2m-client-detail", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients/#{@valid_client_id}")

      refute has_element?(view, "#m2m-client-detail form")
      refute has_element?(view, "#m2m-client-detail [phx-click=\"delete\"]")
      refute has_element?(view, "#m2m-client-detail [phx-click=\"edit\"]")
      refute has_element?(view, "#m2m-client-detail [phx-click=\"rename\"]")

      detail_html =
        view
        |> element("#m2m-client-detail")
        |> render()

      refute detail_html =~ "Delete"
      refute detail_html =~ "Remove"
      refute detail_html =~ "Rename"
      refute detail_html =~ "Edit"
    end
  end

  describe "M2M-A16 — token validity display" do
    @tag action: "M2M-A16"
    test "the fixture with exactly one hour renders \"1 hour\"", %{conn: conn} do
      one_hour_client_id = "9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a"

      {:ok, view, _html} = live(conn, ~p"/m2m/clients/#{one_hour_client_id}")

      assert has_element?(view, "#m2m-client-token-validity", "1 hour")
    end

    @tag action: "M2M-A16"
    test "the fixture with a different value pluralises", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients/#{@valid_client_id}")

      assert has_element?(view, "#m2m-client-token-validity", "15 minutes")
    end

    @tag action: "M2M-A16"
    test "the fixture whose underlying unit is not hours (nor whole minutes) still renders correctly",
         %{conn: conn} do
      seconds_tier_client_id = "1c2d3e4f5a67890b1c2d3e4f5a67890b"

      {:ok, view, _html} = live(conn, ~p"/m2m/clients/#{seconds_tier_client_id}")

      assert has_element?(view, "#m2m-client-token-validity", "450 seconds")
    end
  end

  describe "Show — error states" do
    @error_state_ids %{
      not_configured: "m2m-clients-misconfigured",
      unavailable: "m2m-clients-unavailable",
      auth_expired: "m2m-clients-auth-expired"
    }

    for {kind, expected_id} <- @error_state_ids do
      @tag kind: kind
      @tag expected_id: expected_id
      test "#{kind} renders its own state, shell intact, no detail fields, no crash", %{
        conn: conn,
        kind: kind,
        expected_id: expected_id
      } do
        use_backend(FailingM2MClients)
        Application.put_env(:nucleus, FailingM2MClients, kind)

        assert {:ok, view, _html} = live(conn, ~p"/m2m/clients/#{@valid_client_id}")

        assert has_element?(view, "##{expected_id}")
        refute has_element?(view, "#m2m-client-detail")
        refute has_element?(view, "#m2m-client-invalid-id")
        refute has_element?(view, "#m2m-client-not-found")
        assert has_element?(view, "#tenant-identifier")
      end
    end

    test "live/2 returns {:ok, ...} for every Nucleus.Backend.Error kind — never crashes", %{
      conn: conn
    } do
      for kind <- Error.kinds() do
        use_backend(FailingM2MClients)
        Application.put_env(:nucleus, FailingM2MClients, kind)

        assert {:ok, _view, _html} = live(conn, ~p"/m2m/clients/#{@valid_client_id}")
      end
    end
  end

  describe "Show — mount/3 re-validates on every navigation, not just the first" do
    test "patching from the list to a client, then to a second client, re-validates each time",
         %{conn: conn} do
      second_client_id = "7a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d"

      {:ok, first_view, _html} = live(conn, ~p"/m2m/clients/#{@valid_client_id}")
      assert has_element?(first_view, "#m2m-client-id", @valid_client_id)

      {:ok, second_view, _html} = live(conn, ~p"/m2m/clients/#{second_client_id}")
      assert has_element?(second_view, "#m2m-client-id", second_client_id)

      {:ok, denied_view, _html} = live(conn, ~p"/m2m/clients/#{@denied_client_id}")
      assert has_element?(denied_view, "#m2m-client-not-found")
    end
  end
end
