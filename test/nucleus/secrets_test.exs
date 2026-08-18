defmodule Nucleus.SecretsTest do
  # `seed_secret/3`/`force_error/2` mutate node-global state
  # (`Nucleus.Backend.Seed`); composed with `Nucleus.AuditCase` the same way
  # `NucleusWeb.LiveCase` does, both pinned to `async: false` to match
  # `Nucleus.BackendCase`'s constraint.
  use Nucleus.BackendCase, async: false
  use Nucleus.AuditCase, async: false

  import ExUnit.CaptureLog

  alias Nucleus.Backend.Error
  alias Nucleus.Scope
  alias Nucleus.Secrets
  alias Nucleus.Secrets.Secret
  alias Nucleus.Secrets.SecretRef

  @scope %Scope{tenant: "acme", user: %{email: "a@b.com", username: nil}}
  @db_url_value "postgres://app:s3cr3t@prod-db.internal:5432/app"

  defmodule ExplodingSecretsStore do
    @moduledoc """
    A `Nucleus.Secrets.Store` implementation that raises if it is ever
    called — swapped in for the one test that asserts the environment gate
    holds through the context layer: if `Secrets.list/2` called the store
    after an invalid name, this module raising is how the test would know.
    """
    @behaviour Nucleus.Secrets.Store

    @impl Nucleus.Secrets.Store
    def list_secrets(_environment), do: raise("list_secrets/1 was called after an invalid name")

    @impl Nucleus.Secrets.Store
    def get_secret(_environment, _key), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def create_secret(_environment, _key, _value), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def update_secret(_environment, _key, _value), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def locate_secret(_environment, _key), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def list_environments, do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def list_all_secrets, do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def health_check, do: raise("should not be called")
  end

  defp use_exploding_secrets_store do
    original = Application.get_env(:nucleus, :backends, [])
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)

    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(original, :secrets, ExplodingSecretsStore)
    )
  end

  defmodule FailingGetSecretStore do
    @moduledoc """
    A `Nucleus.Secrets.Store` implementation whose `get_secret/2` always
    fails `:unavailable`, for the `SEC-A05` test that needs a store-level
    failure `reveal/3` cannot short-circuit before reaching.

    `Nucleus.BackendCase.force_error/2` cannot exercise this: the underlying
    `LOCAL_FORCE_ERROR` fault is node-global and checked by
    `Nucleus.TenantApi.Local` too, so it would be caught by `reveal/3`'s
    environment gate first (`boundary: :tenant_api`) and the store would
    never be reached — the same reasoning
    `NucleusWeb.SecretsLiveTest.FailingSecretsStore` documents. Swapping the
    `:secrets` boundary's implementation instead is the only way to force a
    `boundary: :secrets` failure here.
    """
    @behaviour Nucleus.Secrets.Store

    @impl Nucleus.Secrets.Store
    def list_secrets(_environment), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def get_secret(_environment, _key) do
      {:error, Error.new(:unavailable, :secrets, "forced for test", %{})}
    end

    @impl Nucleus.Secrets.Store
    def create_secret(_environment, _key, _value), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def update_secret(_environment, _key, _value), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def locate_secret(_environment, _key), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def list_environments, do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def list_all_secrets, do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def health_check, do: raise("should not be called")
  end

  defp use_failing_get_secret_store do
    original = Application.get_env(:nucleus, :backends, [])
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)

    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(original, :secrets, FailingGetSecretStore)
    )
  end

  describe "list/2 — SEC-A01 shape" do
    @tag action: "SEC-A01"
    test "returns SecretRef structs with key, path, arn populated" do
      assert {:ok, refs} = Secrets.list("prod", @scope)
      assert refs != []

      for ref <- refs do
        assert %SecretRef{} = ref
        assert is_binary(ref.key) and ref.key != ""
        assert is_binary(ref.path) and ref.path != ""
        assert is_binary(ref.arn) and ref.arn != ""
      end
    end

    @tag action: "SEC-A01"
    test "the returned structs have no value key" do
      assert {:ok, [ref | _]} = Secrets.list("prod", @scope)
      refute Map.has_key?(ref, :value)
    end
  end

  describe "list/2 — SEC-A01 sort order" do
    @tag action: "SEC-A01"
    test "results are sorted by key, case-insensitively with a raw-key tiebreak" do
      seed_secret("prod", "api_key_lower", "one")
      seed_secret("prod", "API_KEY_LOWER", "two")

      assert {:ok, refs} = Secrets.list("prod", @scope)
      keys = Enum.map(refs, & &1.key)

      assert keys == Enum.sort_by(keys, &{String.downcase(&1), &1})
    end

    @tag action: "SEC-A01"
    test "ordering is stable across two calls" do
      assert {:ok, first} = Secrets.list("prod", @scope)
      assert {:ok, second} = Secrets.list("prod", @scope)

      assert Enum.map(first, & &1.key) == Enum.map(second, & &1.key)
    end
  end

  describe "list/2 — the environment gate holds through the context layer" do
    @tag action: "SEC-A01"
    test "an invalid environment name returns :invalid without calling the store" do
      use_exploding_secrets_store()

      assert {:error, %Error{kind: :invalid}} = Secrets.list("..", @scope)
    end
  end

  describe "list/2 — SEC-A14 empty state" do
    @tag action: "SEC-A14"
    test "the seeded empty sandbox environment returns {:ok, []}, not an error" do
      assert {:ok, []} = Secrets.list("sandbox", @scope)
    end
  end

  describe "list/2 — no audit event" do
    test "emits none of the three secret audit events" do
      Secrets.list("prod", @scope)

      assert_no_audit_event(:secret_created)
      assert_no_audit_event(:secret_viewed)
      assert_no_audit_event(:secret_updated)
    end

    test "does not leak a seeded secret's value into the audit trail" do
      Secrets.list("prod", @scope)

      refute_audit_contains(@db_url_value)
    end
  end

  describe "reveal/3 — SEC-A03 success" do
    @tag action: "SEC-A03"
    test "returns {:ok, %Secret{value: expected}}" do
      assert {:ok, %Secret{} = secret} = Secrets.reveal("prod", "DATABASE_URL", @scope)

      assert secret.key == "DATABASE_URL"
      assert secret.value == @db_url_value
    end

    @tag action: "SEC-A03"
    test "emits exactly one secret_viewed with resource equal to the full path" do
      assert {:ok, secret} = Secrets.reveal("prod", "DATABASE_URL", @scope)

      assert_audit_event(:secret_viewed, tenant: "acme", resource: secret.path)
      assert length(audit_events()) == 1
    end

    @tag action: "SEC-A03"
    test "user is Scope.audit_user/1's result, falling back to username when email is absent" do
      scope = %Scope{tenant: "acme", user: %{email: nil, username: "auser"}}

      Secrets.reveal("prod", "DATABASE_URL", scope)

      assert_audit_event(:secret_viewed, user: "auser")
    end

    @tag action: "SEC-A03"
    test "resource is the full path, not the bare key" do
      assert {:ok, secret} = Secrets.reveal("prod", "DATABASE_URL", @scope)

      record = assert_audit_event(:secret_viewed)
      assert record.resource == secret.path
      refute record.resource == "DATABASE_URL"
    end

    @tag action: "SEC-A03"
    test "the AUD-A02 guard — the value appears in no audit record" do
      Secrets.reveal("prod", "DATABASE_URL", @scope)

      refute_audit_contains(@db_url_value)
    end

    @tag action: "SEC-A03"
    test "two reveals emit two secret_viewed events" do
      Secrets.reveal("prod", "DATABASE_URL", @scope)
      Secrets.reveal("prod", "DATABASE_URL", @scope)

      events = Enum.filter(audit_events(), &(&1.event == :secret_viewed))
      assert length(events) == 2
    end
  end

  describe "reveal/3 — SEC-A05 failed reveal" do
    @tag action: "SEC-A05"
    test "a store :not_found emits no audit event" do
      assert {:error, %Error{kind: :not_found}} =
               Secrets.reveal("prod", "NO_SUCH_KEY", @scope)

      assert_no_audit_event(:secret_viewed)
    end

    @tag action: "SEC-A05"
    test "a forced store :unavailable emits no audit event" do
      use_failing_get_secret_store()

      assert {:error, %Error{kind: :unavailable, boundary: :secrets}} =
               Secrets.reveal("prod", "DATABASE_URL", @scope)

      assert_no_audit_event(:secret_viewed)
    end

    @tag action: "SEC-A05"
    test "a forged key containing '..' is rejected with :invalid, no store call, no audit event" do
      use_exploding_secrets_store()

      assert {:error, %Error{kind: :invalid}} =
               Secrets.reveal("prod", "../../other-env/secret", @scope)

      assert_no_audit_event(:secret_viewed)
    end

    @tag action: "SEC-A05"
    test "the value appears in no log line, on any branch" do
      log =
        capture_log(fn ->
          Secrets.reveal("prod", "DATABASE_URL", @scope)
          Secrets.reveal("prod", "NO_SUCH_KEY", @scope)
          Secrets.reveal("prod", "../../other-env/secret", @scope)
        end)

      refute log =~ @db_url_value
    end
  end
end
