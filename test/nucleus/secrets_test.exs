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

  defmodule FailingUpdateSecretStore do
    @moduledoc """
    A `Nucleus.Secrets.Store` implementation whose `update_secret/3` always
    fails `:unavailable`, mirroring `FailingGetSecretStore` above — same
    reasoning: `LOCAL_FORCE_ERROR` is node-global and would be intercepted by
    `update/4`'s environment gate (`boundary: :tenant_api`) first.

    `get_secret/2` delegates to the real `Nucleus.Secrets.Store.Local`, so a
    test can still confirm the value is unchanged after a forced update
    failure.
    """
    @behaviour Nucleus.Secrets.Store

    @impl Nucleus.Secrets.Store
    def list_secrets(_environment), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def get_secret(environment, key) do
      Nucleus.Secrets.Store.Local.get_secret(environment, key)
    end

    @impl Nucleus.Secrets.Store
    def create_secret(_environment, _key, _value), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def update_secret(_environment, _key, _value) do
      {:error, Error.new(:unavailable, :secrets, "forced for test", %{})}
    end

    @impl Nucleus.Secrets.Store
    def locate_secret(_environment, _key), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def list_environments, do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def list_all_secrets, do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def health_check, do: raise("should not be called")
  end

  defp use_failing_get_secret_or_update_store do
    original = Application.get_env(:nucleus, :backends, [])
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)

    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(original, :secrets, FailingUpdateSecretStore)
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

  describe "update/4 — SEC-A06 success" do
    @tag action: "SEC-A06"
    test "changes the value; a subsequent reveal/3 returns the new value" do
      assert {:ok, %SecretRef{key: "DATABASE_URL"}} =
               Secrets.update("prod", "DATABASE_URL", "new-value", @scope)

      assert {:ok, %Secret{value: "new-value"}} =
               Secrets.reveal("prod", "DATABASE_URL", @scope)
    end

    @tag action: "SEC-A06"
    test "emits exactly one secret_updated with the full path as resource" do
      assert {:ok, ref} = Secrets.update("prod", "DATABASE_URL", "new-value", @scope)

      assert_audit_event(:secret_updated, tenant: "acme", resource: ref.path)

      events = Enum.filter(audit_events(), &(&1.event == :secret_updated))
      assert length(events) == 1
    end

    @tag action: "SEC-A06"
    test "the AUD-A02 guard — refute_audit_contains/1 for both the old and the new value" do
      Secrets.update("prod", "DATABASE_URL", "new-value", @scope)

      refute_audit_contains(@db_url_value)
      refute_audit_contains("new-value")
    end

    @tag action: "SEC-A06"
    test "user is Scope.audit_user/1's result, falling back to username when email is absent" do
      scope = %Scope{tenant: "acme", user: %{email: nil, username: "auser"}}

      Secrets.update("prod", "DATABASE_URL", "new-value", scope)

      assert_audit_event(:secret_updated, user: "auser")
    end

    @tag action: "SEC-A06"
    test "resource is the full path, not the bare key" do
      assert {:ok, ref} = Secrets.update("prod", "DATABASE_URL", "new-value", @scope)

      record = assert_audit_event(:secret_updated)
      assert record.resource == ref.path
      refute record.resource == "DATABASE_URL"
    end

    @tag action: "SEC-A06"
    test "returns a SecretRef, with no value key" do
      assert {:ok, ref} = Secrets.update("prod", "DATABASE_URL", "new-value", @scope)

      refute Map.has_key?(ref, :value)
    end
  end

  describe "update/4 — SEC-A06 missing key" do
    @tag action: "SEC-A06"
    test "on a missing key returns :not_found, creates nothing, emits no audit event" do
      assert {:error, %Error{kind: :not_found}} =
               Secrets.update("prod", "NO_SUCH_KEY", "value", @scope)

      assert {:error, %Error{kind: :not_found}} =
               Secrets.reveal("prod", "NO_SUCH_KEY", @scope)

      assert_no_audit_event(:secret_updated)
    end
  end

  describe "update/4 — SEC-A08 validation failures" do
    @tag action: "SEC-A08"
    test "an over-4096-character value is :invalid, no store call, no audit event" do
      use_exploding_secrets_store()
      too_long = String.duplicate("a", 4097)

      assert {:error, %Error{kind: :invalid}} =
               Secrets.update("prod", "DATABASE_URL", too_long, @scope)

      assert_no_audit_event(:secret_updated)
    end

    @tag action: "SEC-A08"
    test "an empty value is :invalid" do
      use_exploding_secrets_store()

      assert {:error, %Error{kind: :invalid}} =
               Secrets.update("prod", "DATABASE_URL", "", @scope)

      assert_no_audit_event(:secret_updated)
    end

    @tag action: "SEC-A08"
    test "a forged key containing '..' is :invalid, no store call" do
      use_exploding_secrets_store()

      assert {:error, %Error{kind: :invalid}} =
               Secrets.update("prod", "../../other-env/secret", "value", @scope)

      assert_no_audit_event(:secret_updated)
    end

    @tag action: "SEC-A08"
    test "a forced store :unavailable emits no audit event; the value is unchanged in the store" do
      original = Secrets.Store.get_secret("prod", "DATABASE_URL")
      use_failing_get_secret_or_update_store()

      assert {:error, %Error{kind: :unavailable, boundary: :secrets}} =
               Secrets.update("prod", "DATABASE_URL", "attempted-new-value", @scope)

      assert_no_audit_event(:secret_updated)
      assert original == Secrets.Store.get_secret("prod", "DATABASE_URL")
    end
  end

  describe "update/4 — value length boundary" do
    @tag action: "SEC-A06"
    test "a 4096-character value succeeds; 4097 fails" do
      exactly_max = String.duplicate("a", 4096)
      over_max = String.duplicate("a", 4097)

      assert {:ok, _ref} = Secrets.update("prod", "DATABASE_URL", exactly_max, @scope)

      assert {:error, %Error{kind: :invalid}} =
               Secrets.update("prod", "DATABASE_URL", over_max, @scope)
    end

    @tag action: "SEC-A06"
    test "a multi-byte value of 4096 characters succeeds — String.length, not byte_size" do
      # "é" is two bytes in UTF-8 but one character.
      multibyte_value = String.duplicate("é", 4096)
      assert String.length(multibyte_value) == 4096
      assert byte_size(multibyte_value) > 4096

      assert {:ok, _ref} = Secrets.update("prod", "DATABASE_URL", multibyte_value, @scope)
    end
  end

  describe "update/4 — no value in logs" do
    test "neither the old nor the new value appears in captured log output, success or failure" do
      new_value = "brand-new-value"

      log =
        capture_log(fn ->
          Secrets.update("prod", "DATABASE_URL", new_value, @scope)
          Secrets.update("prod", "NO_SUCH_KEY", new_value, @scope)
          Secrets.update("prod", "DATABASE_URL", "", @scope)
        end)

      refute log =~ @db_url_value
      refute log =~ new_value
    end
  end

  describe "create/4 — SEC-A09 success" do
    @tag action: "SEC-A09"
    test "creates the secret; list/2 then includes it; reveal/3 returns the value" do
      assert {:ok, %SecretRef{key: "NEW_KEY"} = ref} =
               Secrets.create("prod", "NEW_KEY", "new-secret-value", @scope)

      assert {:ok, refs} = Secrets.list("prod", @scope)
      assert Enum.any?(refs, &(&1.key == "NEW_KEY"))

      assert {:ok, %Secret{value: "new-secret-value"}} =
               Secrets.reveal("prod", "NEW_KEY", @scope)

      refute Map.has_key?(ref, :value)
    end

    @tag action: "SEC-A09"
    test "emits exactly one secret_created with the full path as resource" do
      assert {:ok, ref} = Secrets.create("prod", "NEW_KEY", "new-secret-value", @scope)

      assert_audit_event(:secret_created, tenant: "acme", resource: ref.path)

      events = Enum.filter(audit_events(), &(&1.event == :secret_created))
      assert length(events) == 1
    end

    @tag action: "SEC-A09"
    test "resource is the full path, not the bare key" do
      assert {:ok, ref} = Secrets.create("prod", "NEW_KEY", "new-secret-value", @scope)

      record = assert_audit_event(:secret_created)
      assert record.resource == ref.path
      refute record.resource == "NEW_KEY"
    end

    @tag action: "SEC-A09"
    test "user is Scope.audit_user/1's result, falling back to username when email is absent" do
      scope = %Scope{tenant: "acme", user: %{email: nil, username: "auser"}}

      Secrets.create("prod", "NEW_KEY", "new-secret-value", scope)

      assert_audit_event(:secret_created, user: "auser")
    end

    @tag action: "SEC-A09"
    test "the AUD-A02 guard — the value appears in no audit record" do
      Secrets.create("prod", "NEW_KEY", "new-secret-value", @scope)

      refute_audit_contains("new-secret-value")
    end

    @tag action: "SEC-A09"
    test "no secret_viewed is emitted by creation" do
      Secrets.create("prod", "NEW_KEY", "new-secret-value", @scope)

      assert_no_audit_event(:secret_viewed)
    end
  end

  describe "create/4 — SEC-A12 reject an existing key" do
    @tag action: "SEC-A12"
    test "creating an existing key returns :already_exists, leaves the value unchanged, emits no audit event" do
      assert {:error, %Error{kind: :already_exists}} =
               Secrets.create("prod", "DATABASE_URL", "attempted-overwrite", @scope)

      assert {:ok, %Secret{value: @db_url_value}} =
               Secrets.reveal("prod", "DATABASE_URL", @scope)

      assert_no_audit_event(:secret_created)
    end

    @tag action: "SEC-A12"
    test "the value never appears in logs on a rejected create" do
      log =
        capture_log(fn ->
          Secrets.create("prod", "DATABASE_URL", "attempted-overwrite", @scope)
        end)

      refute log =~ "attempted-overwrite"
    end
  end

  describe "create/4 — SEC-A10 invalid key" do
    @tag action: "SEC-A10"
    test "an invalid key returns :invalid, no store call, no audit event" do
      use_exploding_secrets_store()

      assert {:error, %Error{kind: :invalid}} =
               Secrets.create("prod", "../../other-env/secret", "value", @scope)

      assert_no_audit_event(:secret_created)
    end

    @tag action: "SEC-A10"
    test "an empty key returns :invalid" do
      use_exploding_secrets_store()

      assert {:error, %Error{kind: :invalid}} = Secrets.create("prod", "", "value", @scope)

      assert_no_audit_event(:secret_created)
    end
  end

  describe "create/4 — SEC-A11 invalid value" do
    @tag action: "SEC-A11"
    test "an invalid value returns :invalid, no store call" do
      use_exploding_secrets_store()
      too_long = String.duplicate("a", 4097)

      assert {:error, %Error{kind: :invalid}} =
               Secrets.create("prod", "ANOTHER_NEW_KEY", too_long, @scope)

      assert_no_audit_event(:secret_created)
    end

    @tag action: "SEC-A11"
    test "an empty value returns :invalid" do
      use_exploding_secrets_store()

      assert {:error, %Error{kind: :invalid}} =
               Secrets.create("prod", "ANOTHER_NEW_KEY", "", @scope)

      assert_no_audit_event(:secret_created)
    end
  end

  describe "create/4 — the environment gate holds through the context layer" do
    @tag action: "SEC-A09"
    test "an invalid environment name returns :invalid without calling the store" do
      use_exploding_secrets_store()

      assert {:error, %Error{kind: :invalid}} = Secrets.create("..", "NEW_KEY", "value", @scope)
    end
  end

  describe "create/4 — no value in logs" do
    test "the value appears in no captured log output, success or failure" do
      log =
        capture_log(fn ->
          Secrets.create("prod", "NEW_KEY", "brand-new-value", @scope)
          Secrets.create("prod", "DATABASE_URL", "brand-new-value", @scope)
          Secrets.create("prod", "ANOTHER_NEW_KEY", "", @scope)
        end)

      refute log =~ "brand-new-value"
    end
  end
end
