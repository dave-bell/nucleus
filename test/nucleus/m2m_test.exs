defmodule Nucleus.M2MTest do
  # Backend swap (`ExplodingM2MClients`, `use_backend/1`) mutates node-global
  # state (`Nucleus.Backend.Seed`, `:nucleus, :backends`); composed with
  # `Nucleus.AuditCase` the same way `Nucleus.SecretsTest` does, both pinned
  # to `async: false` to match `Nucleus.BackendCase`'s constraint.
  use Nucleus.BackendCase, async: false
  use Nucleus.AuditCase, async: false

  import ExUnit.CaptureLog

  alias Nucleus.Backend.Error
  alias Nucleus.Backend.Seed
  alias Nucleus.M2M
  alias Nucleus.M2M.Client
  alias Nucleus.M2M.ClientCredentials
  alias Nucleus.M2M.ClientDetail
  alias Nucleus.M2M.ClientName
  alias Nucleus.M2M.DenyList
  alias Nucleus.Scope

  @scope %Scope{tenant: "local", user: %{email: "a@b.com", username: nil}}

  # Seeded in priv/backends/local_seed.json under TENANT_NAMESPACE = "local".
  @valid_client_id "4f2a9c1e7b3d8f0a1c2e3f4a5b6c7d8e"
  @valid_client_secret "b1c2d3e4f5a67890b1c2d3e4f5a67890b1c2d3e4f5a67890b1c2d3e4f5a6789"
  @denied_client_id "5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e"
  @out_of_tenant_client_id "6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f"
  @nonexistent_client_id String.duplicate("f", 32)

  defmodule ExplodingM2MClients do
    @moduledoc """
    A `Nucleus.M2M.Clients` implementation that raises if it is ever called —
    swapped in for the tests that assert `M2M-A13`'s "zero adapter calls"
    guarantee. `Nucleus.Backend.Faults`' `LOCAL_FORCE_ERROR` is node-global
    (see `living-notes.md`) and cannot isolate an `:m2m`-boundary fault from
    any other boundary's local implementation, so this swap — the same
    technique `Nucleus.EnvironmentsTest.ExplodingTenantApi` and
    `Nucleus.SecretsTest.ExplodingSecretsStore` use — is the only way to make
    this guarantee structurally checkable.
    """
    @behaviour Nucleus.M2M.Clients

    @impl Nucleus.M2M.Clients
    def list_clients, do: raise("list_clients/0 was called — zero adapter calls expected")

    @impl Nucleus.M2M.Clients
    def describe_client(_client_id),
      do: raise("describe_client/1 was called — zero adapter calls expected")

    @impl Nucleus.M2M.Clients
    def create_client(_client_name, _settings), do: raise("should not be called")

    @impl Nucleus.M2M.Clients
    def rotate_secret(_client_id), do: raise("should not be called")

    @impl Nucleus.M2M.Clients
    def health_check, do: raise("should not be called")
  end

  defmodule FailingM2MClients do
    @moduledoc """
    A `Nucleus.M2M.Clients` implementation whose `describe_client/1` and
    `list_clients/0` always return a controllable `Nucleus.Backend.Error`,
    for asserting that `Nucleus.M2M.fetch/2` and `Nucleus.M2M.list/1` pass a
    given error kind through unchanged.

    A swapped module, not `LOCAL_FORCE_ERROR`: `Nucleus.Backend.Faults` is
    node-global (`living-notes.md`) and the `:m2m` boundary's `Clients.Local`
    checks it first thing on every callback, same as every other local
    implementation — a swapped module is the only way to control the
    returned kind precisely, per test, without leaking into any other
    boundary the same `async: false` suite might touch.
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
    def rotate_secret(_client_id) do
      kind = Application.get_env(:nucleus, __MODULE__, :unavailable)
      {:error, Error.new(kind, :m2m, "forced for test", %{})}
    end

    @impl Nucleus.M2M.Clients
    def health_check, do: raise("should not be called")
  end

  defmodule EmptyM2MClients do
    @moduledoc """
    A `Nucleus.M2M.Clients` implementation whose `list_clients/0` always
    succeeds with zero clients — `M2M-A02`'s "an empty tenant" fixture,
    distinct from an error: `{:ok, []}` must not be confused with a failed
    list.
    """
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

  defmodule DegradedRowM2MClients do
    @moduledoc """
    A `Nucleus.M2M.Clients` implementation whose `list_clients/0` returns a
    single in-tenant, non-denied client with `created_date_error` set instead
    of `created_date` — EN-10 / #33's Decision 6 fixture: a per-row describe
    failure while listing degrades that one row rather than failing the
    whole list, and `Nucleus.M2M.list/1` must return it, not drop it.
    """
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

  defp unconfigure_deny_list do
    original = Application.get_env(:nucleus, DenyList, [])
    on_exit(fn -> Application.put_env(:nucleus, DenyList, original) end)
    Application.put_env(:nucleus, DenyList, [])
  end

  # The only way, against the local backend, to prove "the old secret
  # remains valid until the next rotation" structurally rather than by
  # inference: `ClientDetail` carries no `secrets` field (it never should —
  # see `ClientCredentials`'s own moduledoc), so this reads the seed's
  # internal state directly, the same technique
  # `Nucleus.M2M.Clients.LocalTest` uses for the identical assertion one
  # boundary lower.
  defp seeded_secrets(client_id) do
    Seed.read(:m2m) |> get_in([client_id, "secrets"])
  end

  describe "fetch/2 — M2M-A13 malformed client ID" do
    @tag action: "M2M-A13"
    @tag :unit
    test "every malformed ID returns kind: :invalid" do
      malformed = [
        "",
        nil,
        :abc,
        "../etc",
        "abc/def",
        "abc\\def",
        "ab\0c",
        "abc def",
        String.duplicate("a", 129),
        "abc\uFF0Fdef",
        "%2e%2e"
      ]

      for client_id <- malformed do
        assert {:error, %Error{kind: :invalid}} = M2M.fetch(client_id, @scope)
      end
    end

    @tag action: "M2M-A13"
    test "a malformed ID results in zero calls to Clients.describe_client/1" do
      use_backend(ExplodingM2MClients)

      assert {:error, %Error{kind: :invalid}} = M2M.fetch("../etc", @scope)
    end
  end

  describe "fetch/2 — M2M-A14 out-of-tenant and deny-listed clients" do
    @tag action: "M2M-A14"
    test "the seeded out-of-tenant fixture returns kind: :not_found" do
      assert {:error, %Error{kind: :not_found}} = M2M.fetch(@out_of_tenant_client_id, @scope)
    end

    @tag action: "M2M-A14"
    test "the seeded deny-listed fixture returns kind: :not_found" do
      assert {:error, %Error{kind: :not_found}} = M2M.fetch(@denied_client_id, @scope)
    end

    @tag action: "M2M-A14"
    test "deny-listed and genuinely nonexistent are structurally identical — never exposed here" do
      {:error, deny_listed_error} = M2M.fetch(@denied_client_id, @scope)
      {:error, nonexistent_error} = M2M.fetch(@nonexistent_client_id, @scope)

      assert deny_listed_error.kind == nonexistent_error.kind
      assert deny_listed_error.message == nonexistent_error.message
      assert Map.keys(deny_listed_error.details) == Map.keys(nonexistent_error.details)
    end

    @tag action: "M2M-A14"
    test "out-of-tenant and genuinely nonexistent are structurally identical — never exposed here" do
      {:error, out_of_tenant_error} = M2M.fetch(@out_of_tenant_client_id, @scope)
      {:error, nonexistent_error} = M2M.fetch(@nonexistent_client_id, @scope)

      assert out_of_tenant_error.kind == nonexistent_error.kind
      assert out_of_tenant_error.message == nonexistent_error.message
      assert Map.keys(out_of_tenant_error.details) == Map.keys(nonexistent_error.details)
    end
  end

  describe "fetch/2 — a valid in-tenant client" do
    test "resolves to {:ok, %ClientDetail{}}" do
      assert {:ok, %ClientDetail{} = detail} = M2M.fetch(@valid_client_id, @scope)
      assert detail.client_id == @valid_client_id
    end

    test "the resolved struct has no :client_secret key" do
      assert {:ok, detail} = M2M.fetch(@valid_client_id, @scope)
      refute Map.has_key?(detail, :client_secret)
    end
  end

  describe "fetch/2 — error pass-through" do
    test ":auth_expired passes through unchanged" do
      use_backend(FailingM2MClients)
      Application.put_env(:nucleus, FailingM2MClients, :auth_expired)

      assert {:error, %Error{kind: :auth_expired}} = M2M.fetch(@valid_client_id, @scope)
    end

    test ":unavailable passes through unchanged" do
      use_backend(FailingM2MClients)
      Application.put_env(:nucleus, FailingM2MClients, :unavailable)

      assert {:error, %Error{kind: :unavailable}} = M2M.fetch(@valid_client_id, @scope)
    end
  end

  describe "fetch/2 — unconfigured deny-list fails closed" do
    test "returns :not_configured, with zero adapter calls" do
      unconfigure_deny_list()
      use_backend(ExplodingM2MClients)

      assert {:error, %Error{kind: :not_configured}} = M2M.fetch(@valid_client_id, @scope)
    end
  end

  describe "fetch/2 — no audit event" do
    test "emits none of the three m2m_* events" do
      assert {:ok, _detail} = M2M.fetch(@valid_client_id, @scope)
      assert {:error, _} = M2M.fetch(@denied_client_id, @scope)
      assert {:error, _} = M2M.fetch("bad id", @scope)

      assert_no_audit_event(:m2m_client_viewed)
      assert_no_audit_event(:m2m_client_created)
      assert_no_audit_event(:m2m_secret_rotated)
    end
  end

  describe "visible?/1 — the shared predicate" do
    test "true for a resolved in-tenant, non-denied client" do
      assert {:ok, detail} = M2M.fetch(@valid_client_id, @scope)
      assert M2M.visible?(detail)
    end
  end

  describe "list/1 — M2M-A01 lists the tenant's visible clients" do
    @tag action: "M2M-A01"
    test "returns Client structs with client_id, client_name, created_date populated" do
      assert {:ok, clients} = M2M.list(@scope)
      assert clients != []

      for client <- clients do
        assert %Client{} = client
        assert is_binary(client.client_id)
        assert is_binary(client.client_name)
      end

      assert Enum.any?(clients, &(&1.client_id == @valid_client_id))
      assert Enum.any?(clients, & &1.created_date)
    end

    @tag action: "M2M-A01"
    test "the returned structs have no :client_secret key" do
      assert {:ok, clients} = M2M.list(@scope)
      assert clients != []

      for client <- clients do
        refute Map.has_key?(client, :client_secret)
      end
    end

    @tag action: "M2M-A01"
    test "the seeded deny-listed client is absent from the result" do
      assert {:ok, clients} = M2M.list(@scope)
      refute Enum.any?(clients, &(&1.client_id == @denied_client_id))
    end

    @tag action: "M2M-A01"
    test "the seeded out-of-tenant client is absent from the result" do
      assert {:ok, clients} = M2M.list(@scope)
      refute Enum.any?(clients, &(&1.client_id == @out_of_tenant_client_id))
    end

    @tag action: "M2M-A01"
    test "a client hidden from list/1 also returns :not_found from fetch/2 — the two paths are pinned together" do
      assert {:ok, clients} = M2M.list(@scope)
      listed_ids = MapSet.new(clients, & &1.client_id)

      refute MapSet.member?(listed_ids, @denied_client_id)
      assert {:error, %Error{kind: :not_found}} = M2M.fetch(@denied_client_id, @scope)

      refute MapSet.member?(listed_ids, @out_of_tenant_client_id)
      assert {:error, %Error{kind: :not_found}} = M2M.fetch(@out_of_tenant_client_id, @scope)
    end

    @tag action: "M2M-A01"
    test "results are sorted case-insensitively, and the order is identical across two calls" do
      assert {:ok, first} = M2M.list(@scope)
      assert {:ok, second} = M2M.list(@scope)

      names = Enum.map(first, & &1.client_name)
      assert names == Enum.sort_by(names, &String.downcase/1)
      assert Enum.map(second, & &1.client_id) == Enum.map(first, & &1.client_id)
    end

    @tag action: "M2M-A01"
    test "a Client with created_date_error set (not created_date) is still returned, not dropped" do
      use_backend(DegradedRowM2MClients)

      assert {:ok, [client]} = M2M.list(@scope)
      assert client.created_date == nil
      assert client.created_date_error == :unavailable
    end
  end

  describe "list/1 — M2M-A02 empty state" do
    @tag action: "M2M-A02"
    test "an empty m2m seed section returns {:ok, []}, not an error" do
      use_backend(EmptyM2MClients)

      assert {:ok, []} = M2M.list(@scope)
    end
  end

  describe "list/1 — unconfigured deny-list fails closed" do
    test "returns :not_configured, with zero adapter calls" do
      unconfigure_deny_list()
      use_backend(ExplodingM2MClients)

      assert {:error, %Error{kind: :not_configured}} = M2M.list(@scope)
    end
  end

  describe "list/1 — no audit event" do
    test "emits none of the three m2m_* events" do
      assert {:ok, _clients} = M2M.list(@scope)

      assert_no_audit_event(:m2m_client_viewed)
      assert_no_audit_event(:m2m_client_created)
      assert_no_audit_event(:m2m_secret_rotated)
    end
  end

  describe "list/1 — error kinds pass through unflattened" do
    for kind <- Error.kinds() -- [:not_configured] do
      @tag kind: kind
      test "#{kind} is returned unflattened", %{kind: kind} do
        use_backend(FailingM2MClients)
        Application.put_env(:nucleus, FailingM2MClients, kind)

        assert {:error, %Error{kind: ^kind}} = M2M.list(@scope)
      end
    end
  end

  describe "view/2 — M2M-A03 resolves and audits a client view" do
    @tag action: "M2M-A03"
    test "returns a ClientDetail with client_id, client_name, scope, token_validity_seconds, and created_date populated" do
      assert {:ok, %ClientDetail{} = detail} = M2M.view(@valid_client_id, @scope)

      assert detail.client_id == @valid_client_id
      assert is_binary(detail.client_name)
      assert is_binary(detail.scope)
      assert is_integer(detail.token_validity_seconds)
      assert %DateTime{} = detail.created_date
    end

    @tag action: "M2M-A03"
    test "the resolved struct has no :client_secret key" do
      assert {:ok, detail} = M2M.view(@valid_client_id, @scope)
      refute Map.has_key?(detail, :client_secret)
    end

    @tag action: "M2M-A03"
    test "emits exactly one m2m_client_viewed, with client_name in details and the tenant set" do
      assert {:ok, detail} = M2M.view(@valid_client_id, @scope)

      assert_audit_event(:m2m_client_viewed,
        tenant: "local",
        details: %{client_name: detail.client_name}
      )

      assert audit_events() |> Enum.filter(&(&1.event == :m2m_client_viewed)) |> length() == 1
    end

    @tag action: "M2M-A03"
    test "a view that did not happen is not recorded: :invalid emits no audit event" do
      assert {:error, %Error{kind: :invalid}} = M2M.view("../etc", @scope)
      assert_no_audit_event(:m2m_client_viewed)
    end

    @tag action: "M2M-A03"
    test "a view that did not happen is not recorded: :not_found (deny-listed) emits no audit event" do
      assert {:error, %Error{kind: :not_found}} = M2M.view(@denied_client_id, @scope)
      assert_no_audit_event(:m2m_client_viewed)
    end

    @tag action: "M2M-A03"
    test "a view that did not happen is not recorded: :unavailable emits no audit event" do
      use_backend(FailingM2MClients)
      Application.put_env(:nucleus, FailingM2MClients, :unavailable)

      assert {:error, %Error{kind: :unavailable}} = M2M.view(@valid_client_id, @scope)
      assert_no_audit_event(:m2m_client_viewed)
    end

    @tag action: "M2M-A03"
    test "fetch/2 still emits nothing — M2M-S1 / #34's guarantee, re-asserted so this ticket cannot break it" do
      assert {:ok, _detail} = M2M.fetch(@valid_client_id, @scope)
      assert_no_audit_event(:m2m_client_viewed)
    end

    @tag action: "M2M-A03"
    test "the seeded client's secret never appears in the audit trail" do
      assert {:ok, _detail} = M2M.view(@valid_client_id, @scope)
      refute_audit_contains(@valid_client_secret)
    end
  end

  describe "create/4 — M2M-A08 create a client" do
    @tag action: "M2M-A08"
    test "returns a ClientCredentials with a non-empty secret; list/1 afterwards includes the new client" do
      assert {:ok, %ClientCredentials{} = credentials} =
               M2M.create("OPS-5001", "nightly-sync", 15, @scope)

      assert is_binary(credentials.client_id) and credentials.client_id != ""
      assert is_binary(credentials.client_secret) and credentials.client_secret != ""

      assert {:ok, clients} = M2M.list(@scope)
      assert Enum.any?(clients, &(&1.client_id == credentials.client_id))
    end

    @tag action: "M2M-A08"
    test "the created client's name equals ClientName.build/2 for the same inputs" do
      assert {:ok, credentials} = M2M.create("OPS-5002", "billing-export", 15, @scope)
      assert credentials.client_name == ClientName.build("OPS-5002", "billing-export")
    end

    # `create/4`'s own `@spec` (`ticket_id`, `purpose`, `token_validity_minutes`,
    # `scope`) has no parameter a caller could use to supply a full name —
    # this proves the *behavioural* half: a hostile `purpose`, already
    # rejected by `Nucleus.M2M.Purpose.validate/1`, reaches
    # `Clients.create_client/2` zero times.
    @tag action: "M2M-A08"
    test "a caller-supplied name cannot influence the created name — a hostile purpose rejected by validation creates nothing" do
      use_backend(ExplodingM2MClients)

      assert {:error, %Error{kind: :invalid}} = M2M.create("OPS-5003", "Not Valid!", 15, @scope)
    end

    @tag action: "M2M-A08"
    test "emits exactly one m2m_client_created, with client_name and ticket_id in details" do
      assert {:ok, credentials} = M2M.create("OPS-5004", "reporting", 15, @scope)

      assert_audit_event(:m2m_client_created,
        tenant: "local",
        details: %{client_name: credentials.client_name, ticket_id: "OPS-5004"}
      )

      assert audit_events() |> Enum.filter(&(&1.event == :m2m_client_created)) |> length() == 1
    end

    @tag action: "M2M-A08"
    test "the actual generated secret never appears in the audit trail" do
      assert {:ok, credentials} = M2M.create("OPS-5005", "audit-check", 15, @scope)
      refute_audit_contains(credentials.client_secret)
    end

    @tag action: "M2M-A08"
    test "the secret appears in no captured log output, on the success path and on each failure path" do
      log =
        capture_log(fn ->
          {:ok, credentials} = M2M.create("OPS-5006", "log-check", 15, @scope)
          Process.put(:credentials, credentials)

          M2M.create("OPS-5006", "nucleus", 15, @scope)
          M2M.create("", "", 15, @scope)
          M2M.create("OPS-5006", "log-check", 999, @scope)
        end)

      credentials = Process.get(:credentials)
      refute log =~ credentials.client_secret
    end

    @tag action: "M2M-A08"
    test "no m2m_client_viewed is emitted by creation — creating is not viewing" do
      assert {:ok, _credentials} = M2M.create("OPS-5007", "view-check", 15, @scope)
      assert_no_audit_event(:m2m_client_viewed)
    end

    @tag action: "M2M-A08"
    test "invalid ticket ID or purpose returns :invalid, with no backend call and no audit event" do
      use_backend(ExplodingM2MClients)

      assert {:error, %Error{kind: :invalid}} = M2M.create("ops-1234", "nightly-sync", 15, @scope)
      assert {:error, %Error{kind: :invalid}} = M2M.create("OPS-1234", "Not Valid!", 15, @scope)

      assert_no_audit_event(:m2m_client_created)
    end

    @tag action: "M2M-A08"
    test "list/1 and fetch/2 results still have no :client_secret key after a create" do
      assert {:ok, credentials} = M2M.create("OPS-5008", "secret-shape", 15, @scope)

      assert {:ok, clients} = M2M.list(@scope)
      client = Enum.find(clients, &(&1.client_id == credentials.client_id))
      refute Map.has_key?(client, :client_secret)

      assert {:ok, detail} = M2M.fetch(credentials.client_id, @scope)
      refute Map.has_key?(detail, :client_secret)
    end
  end

  describe "create/4 — M2M-A18 reject a reserved client name" do
    @tag action: "M2M-A18"
    test "a purpose whose built name ends with a configured deny-list suffix is rejected, with no audit event and zero calls to Clients.create_client/2" do
      use_backend(ExplodingM2MClients)

      assert {:error, %Error{kind: :invalid, details: %{reason: :reserved_name}}} =
               M2M.create("OPS-6001", "nucleus", 15, @scope)

      assert_no_audit_event(:m2m_client_created)
    end

    @tag action: "M2M-A18"
    test "a purpose that is merely a substring of a reserved suffix, not a suffix of the built name, is not rejected" do
      assert {:ok, _credentials} = M2M.create("OPS-6002", "nucleus-relay", 15, @scope)
    end

    # A misconfigured (unreadable) deny-list must surface as its own
    # `:not_configured` kind, not as a false `:reserved_name` rejection —
    # `DenyList.denied?/1` alone fails closed (`true`) when `suffixes/0`
    # itself errors, which would otherwise reject every input, however
    # harmless, with the wrong `Error.kind` and misleading copy ("choose a
    # different purpose" when no purpose would ever work). Mirrors
    # `fetch/2`'s own "unconfigured deny-list fails closed" coverage.
    test "an unconfigured deny-list returns :not_configured, not :reserved_name, with zero calls to Clients.create_client/2" do
      unconfigure_deny_list()
      use_backend(ExplodingM2MClients)

      assert {:error, %Error{kind: :not_configured}} =
               M2M.create("OPS-6003", "harmless-purpose", 15, @scope)

      assert_no_audit_event(:m2m_client_created)
    end
  end

  describe "rotate/2 — M2M-A11 rotate a client's secret" do
    @tag action: "M2M-A11"
    test "returns a ClientCredentials whose client_id is identical to the input" do
      assert {:ok, credentials} = M2M.create("OPS-7001", "rotate-check", 15, @scope)

      assert {:ok, %ClientCredentials{} = rotated} = M2M.rotate(credentials.client_id, @scope)
      assert rotated.client_id == credentials.client_id
    end

    @tag action: "M2M-A11"
    test "the returned secret differs from the client's previous secret" do
      assert {:ok, credentials} = M2M.create("OPS-7002", "rotate-check", 15, @scope)

      assert {:ok, rotated} = M2M.rotate(credentials.client_id, @scope)
      refute rotated.client_secret == credentials.client_secret
    end

    @tag action: "M2M-A11"
    test "after one rotation, the previous secret is still present on the client" do
      assert {:ok, credentials} = M2M.create("OPS-7003", "rotate-check", 15, @scope)
      assert {:ok, rotated} = M2M.rotate(credentials.client_id, @scope)

      values = credentials.client_id |> seeded_secrets() |> Enum.map(& &1["value"])
      assert credentials.client_secret in values
      assert rotated.client_secret in values
    end

    # The test the ticket itself names as the one that catches every
    # ordering mistake (add-before-delete, delete-the-newer-secret,
    # delete-unconditionally) — together with the assertion above, this is
    # the proof of "valid until the next rotation."
    @tag action: "M2M-A11"
    test "after two rotations, the original secret is gone and the intermediate one remains" do
      assert {:ok, credentials} = M2M.create("OPS-7004", "rotate-check", 15, @scope)
      assert {:ok, first} = M2M.rotate(credentials.client_id, @scope)
      assert {:ok, second} = M2M.rotate(credentials.client_id, @scope)

      values = credentials.client_id |> seeded_secrets() |> Enum.map(& &1["value"])
      refute credentials.client_secret in values
      assert first.client_secret in values
      assert second.client_secret in values
    end

    @tag action: "M2M-A11"
    test "rotating a client with only one secret performs no delete and succeeds" do
      assert {:ok, credentials} = M2M.create("OPS-7005", "rotate-check", 15, @scope)
      assert length(seeded_secrets(credentials.client_id)) == 1

      assert {:ok, _rotated} = M2M.rotate(credentials.client_id, @scope)
      assert length(seeded_secrets(credentials.client_id)) == 2
    end

    # Rotation is not an update (`M2M-A15`) — every other field is untouched.
    @tag action: "M2M-A11"
    test "the client's name, scope, token validity and creation date are unchanged by rotation" do
      assert {:ok, credentials} = M2M.create("OPS-7006", "rotate-check", 15, @scope)
      assert {:ok, before_rotation} = M2M.fetch(credentials.client_id, @scope)

      assert {:ok, _rotated} = M2M.rotate(credentials.client_id, @scope)
      assert {:ok, after_rotation} = M2M.fetch(credentials.client_id, @scope)

      assert after_rotation.client_name == before_rotation.client_name
      assert after_rotation.scope == before_rotation.scope
      assert after_rotation.token_validity_seconds == before_rotation.token_validity_seconds
      assert after_rotation.created_date == before_rotation.created_date
    end

    @tag action: "M2M-A11"
    test "emits exactly one m2m_secret_rotated, with client_name in details and the tenant set" do
      assert {:ok, credentials} = M2M.create("OPS-7007", "rotate-check", 15, @scope)
      assert {:ok, _rotated} = M2M.rotate(credentials.client_id, @scope)

      assert_audit_event(:m2m_secret_rotated,
        tenant: "local",
        details: %{client_name: credentials.client_name}
      )

      assert audit_events() |> Enum.filter(&(&1.event == :m2m_secret_rotated)) |> length() == 1
    end

    @tag action: "M2M-A11"
    test "the new secret appears in no audit record, and in no captured log output on success or failure" do
      log =
        capture_log(fn ->
          {:ok, credentials} = M2M.create("OPS-7008", "rotate-check", 15, @scope)
          {:ok, rotated} = M2M.rotate(credentials.client_id, @scope)
          Process.put(:rotated, rotated)

          M2M.rotate(@nonexistent_client_id, @scope)
          M2M.rotate("bad id", @scope)
        end)

      rotated = Process.get(:rotated)
      refute_audit_contains(rotated.client_secret)
      refute log =~ rotated.client_secret
    end

    @tag action: "M2M-A11"
    test "no m2m_client_viewed is emitted by rotation — the trail must not record a view that did not happen" do
      assert {:ok, credentials} = M2M.create("OPS-7009", "rotate-check", 15, @scope)
      assert {:ok, _rotated} = M2M.rotate(credentials.client_id, @scope)

      assert_no_audit_event(:m2m_client_viewed)
    end

    @tag action: "M2M-A11"
    test "a failed rotation emits no audit event" do
      use_backend(FailingM2MClients)
      Application.put_env(:nucleus, FailingM2MClients, :unavailable)

      assert {:error, %Error{kind: :unavailable}} = M2M.rotate(@valid_client_id, @scope)
      assert_no_audit_event(:m2m_secret_rotated)
    end

    @tag action: "M2M-A11"
    test "rotate/2 on a malformed ID returns :invalid with zero backend calls" do
      use_backend(ExplodingM2MClients)

      assert {:error, %Error{kind: :invalid}} = M2M.rotate("../etc", @scope)
    end
  end

  describe "rotate/2 — M2M-A14 deny-listed and out-of-tenant clients cannot be rotated" do
    @tag action: "M2M-A14"
    test "the seeded deny-listed client returns :not_found, rotates nothing, and emits nothing" do
      secrets_before = seeded_secrets(@denied_client_id)

      assert {:error, %Error{kind: :not_found}} = M2M.rotate(@denied_client_id, @scope)

      assert seeded_secrets(@denied_client_id) == secrets_before
      assert_no_audit_event(:m2m_secret_rotated)
    end

    @tag action: "M2M-A14"
    test "the seeded out-of-tenant client returns :not_found, rotates nothing, and emits nothing" do
      secrets_before = seeded_secrets(@out_of_tenant_client_id)

      assert {:error, %Error{kind: :not_found}} = M2M.rotate(@out_of_tenant_client_id, @scope)

      assert seeded_secrets(@out_of_tenant_client_id) == secrets_before
      assert_no_audit_event(:m2m_secret_rotated)
    end
  end
end
