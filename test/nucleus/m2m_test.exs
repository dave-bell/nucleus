defmodule Nucleus.M2MTest do
  # Backend swap (`ExplodingM2MClients`, `use_backend/1`) mutates node-global
  # state (`Nucleus.Backend.Seed`, `:nucleus, :backends`); composed with
  # `Nucleus.AuditCase` the same way `Nucleus.SecretsTest` does, both pinned
  # to `async: false` to match `Nucleus.BackendCase`'s constraint.
  use Nucleus.BackendCase, async: false
  use Nucleus.AuditCase, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.M2M
  alias Nucleus.M2M.ClientDetail
  alias Nucleus.M2M.DenyList
  alias Nucleus.Scope

  @scope %Scope{tenant: "local", user: %{email: "a@b.com", username: nil}}

  # Seeded in priv/backends/local_seed.json under TENANT_NAMESPACE = "local".
  @valid_client_id "4f2a9c1e7b3d8f0a1c2e3f4a5b6c7d8e"
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
    A `Nucleus.M2M.Clients` implementation whose `describe_client/1` always
    returns a controllable `Nucleus.Backend.Error`, for asserting that
    `Nucleus.M2M.fetch/2` passes a given error kind through unchanged.
    """
    @behaviour Nucleus.M2M.Clients

    @impl Nucleus.M2M.Clients
    def list_clients, do: raise("should not be called")

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
end
