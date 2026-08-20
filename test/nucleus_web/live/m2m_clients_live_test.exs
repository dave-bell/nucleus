defmodule NucleusWeb.M2MClientsLiveTest do
  # Backend swap (`use_backend/1`) mutates node-global `:nucleus, :backends`
  # config, matching `Nucleus.M2MTest`'s own constraint — `async: false`.
  use NucleusWeb.LiveCase, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.M2M.Client

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

  describe "placeholder create handler" do
    test "clicking #new-m2m-client-button does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/m2m/clients")

      html =
        view
        |> element("#new-m2m-client-button")
        |> render_click()

      assert html =~ "M2M Clients"
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
