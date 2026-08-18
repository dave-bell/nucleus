defmodule Nucleus.SecretsTest do
  # `seed_secret/3`/`force_error/2` mutate node-global state
  # (`Nucleus.Backend.Seed`); composed with `Nucleus.AuditCase` the same way
  # `NucleusWeb.LiveCase` does, both pinned to `async: false` to match
  # `Nucleus.BackendCase`'s constraint.
  use Nucleus.BackendCase, async: false
  use Nucleus.AuditCase, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Scope
  alias Nucleus.Secrets
  alias Nucleus.Secrets.SecretRef

  @scope %Scope{tenant: "acme", user: %{email: "a@b.com", username: nil}}

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

      refute_audit_contains("postgres://app:s3cr3t@prod-db.internal:5432/app")
    end
  end
end
