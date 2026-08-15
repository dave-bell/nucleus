defmodule Nucleus.EnvironmentsTest do
  # `force_error/2` and the backend swap in the "zero adapter calls" test both
  # mutate node-global state (`LOCAL_FORCE_ERROR`, `:nucleus, :backends`).
  use Nucleus.BackendCase, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Environments

  defmodule ExplodingTenantApi do
    @moduledoc """
    A `Nucleus.TenantApi` implementation that raises if it is ever called.

    Swapped in for the one test that asserts `SEC-A15`'s "zero adapter calls"
    guarantee: if `Environments.fetch/2` called `list_environments/1` after an
    invalid name, this module raising is how the test would know.
    """
    @behaviour Nucleus.TenantApi

    @impl Nucleus.TenantApi
    def list_environments(_token) do
      raise "list_environments/1 was called — SEC-A15 requires zero adapter calls for an invalid name"
    end

    @impl Nucleus.TenantApi
    def health_check, do: :ok
  end

  defp use_exploding_tenant_api do
    original = Application.get_env(:nucleus, :backends, [])
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)

    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(original, :tenant_api, ExplodingTenantApi)
    )
  end

  describe "validate_name/1 — SEC-A15" do
    @tag action: "SEC-A15"
    @tag :unit
    test "rejects path-traversal and malformed names" do
      invalid = [
        "..",
        "../other",
        "prod/..",
        "prod/sub",
        "prod\\sub",
        "pro\0d",
        "",
        nil,
        :prod,
        String.duplicate("a", 65),
        "%2e%2e",
        "PROD",
        "-prod",
        "prod ",
        "prod\uFF0Fsub"
      ]

      for name <- invalid do
        assert {:error, %Error{kind: :invalid}} = Environments.validate_name(name),
               "expected #{inspect(name)} to be rejected"
      end
    end

    @tag action: "SEC-A15"
    @tag :unit
    test "accepts well-formed short names" do
      valid = ["prod", "staging", "dev", "legacy-qa", "sandbox"]

      for name <- valid do
        assert Environments.validate_name(name) == :ok,
               "expected #{inspect(name)} to be accepted"
      end
    end

    @tag action: "SEC-A15"
    @tag :unit
    test "the double-encoded traversal case specifically" do
      # Phoenix has already percent-decoded once by the time a path segment
      # reaches `handle_params/3`, so `%2e%2e` arrives as literal text and is
      # caught by the charset allowlist (no denylist needed). `%252e` is the
      # case a denylist of `..`/`/`/`\` would miss: it decodes only once, to
      # `%2e`, which still fails the allowlist because `%` is not permitted.
      assert {:error, %Error{kind: :invalid}} = Environments.validate_name("%252e%252e")
    end
  end

  describe "fetch/2 — SEC-A15 zero adapter calls" do
    @tag action: "SEC-A15"
    @tag :unit
    test "an invalid name never reaches TenantApi.list_environments/1" do
      use_exploding_tenant_api()

      assert {:error, %Error{kind: :invalid}} = Environments.fetch("..", nil)
    end
  end

  describe "fetch/2 — SEC-A16 reject a well-formed but unknown environment" do
    @tag action: "SEC-A16"
    @tag :unit
    test "a well-formed unknown name resolves to :not_found" do
      assert {:error, %Error{kind: :not_found}} = Environments.fetch("nope", nil)
    end
  end

  describe "fetch/2 — SEC-A17 fail closed when validation is unavailable" do
    @tag action: "SEC-A17"
    @tag :unit
    test "an unavailable tenant API resolves to :unavailable" do
      force_error(:tenant_api, :unavailable)

      assert {:error, %Error{kind: :unavailable}} = Environments.fetch("prod", nil)
    end

    @tag action: "SEC-A17"
    @tag :unit
    test "a not_configured tenant API also fails closed as :unavailable" do
      force_error(:tenant_api, :not_configured)

      assert {:error, %Error{kind: :unavailable}} = Environments.fetch("prod", nil)
    end
  end

  describe "fetch/2 — auth_expired passes through untouched" do
    @tag :unit
    test "does not get rewritten to :unavailable" do
      force_error(:tenant_api, :auth_expired)

      assert {:error, %Error{kind: :auth_expired}} = Environments.fetch("prod", nil)
    end
  end

  describe "fetch/2 — ENV-A06 archived environments resolve" do
    @tag :unit
    test "an archived environment is found, not treated as not_found" do
      assert {:ok, environment} = Environments.fetch("legacy-qa", nil)
      assert environment.short_name == "legacy-qa"
      assert environment.archived? == true
    end
  end

  describe "fetch/2 — happy path" do
    @tag :unit
    test "resolves a known, active environment" do
      assert {:ok, environment} = Environments.fetch("prod", nil)
      assert environment.short_name == "prod"
    end
  end
end
