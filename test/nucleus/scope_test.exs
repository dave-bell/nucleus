defmodule Nucleus.ScopeTest do
  use ExUnit.Case, async: true

  alias Nucleus.Scope

  doctest Nucleus.Scope

  describe "authenticated?/1" do
    @tag :unit
    test "false when user is nil" do
      refute Scope.authenticated?(%Scope{user: nil})
    end

    @tag :unit
    test "true when user is present" do
      assert Scope.authenticated?(%Scope{user: %{email: "a@b.com", username: nil}})
    end
  end

  describe "audit_user/1" do
    @tag :unit
    test "prefers email when present" do
      scope = %Scope{user: %{email: "a@b.com", username: "auser"}}

      assert Scope.audit_user(scope) == "a@b.com"
    end

    @tag :unit
    test "falls back to username when email is nil" do
      scope = %Scope{user: %{email: nil, username: "auser"}}

      assert Scope.audit_user(scope) == "auser"
    end

    @tag :unit
    test "falls back to username when email is an empty string" do
      scope = %Scope{user: %{email: "", username: "auser"}}

      assert Scope.audit_user(scope) == "auser"
    end

    @tag :unit
    test "falls back to anonymous when there is no user" do
      assert Scope.audit_user(%Scope{user: nil}) == "anonymous"
    end

    @tag :unit
    test "falls back to anonymous when neither email nor username is present" do
      assert Scope.audit_user(%Scope{user: %{email: nil, username: nil}}) == "anonymous"
    end
  end

  describe "tenant_namespace/0" do
    @tag :unit
    test "reads config :nucleus, Nucleus.Scope, :tenant_namespace" do
      original = Application.get_env(:nucleus, Scope)
      on_exit(fn -> Application.put_env(:nucleus, Scope, original) end)

      Application.put_env(:nucleus, Scope, tenant_namespace: "acme")

      assert Scope.tenant_namespace() == "acme"
    end

    @tag :unit
    test "defaults to \"local\" when unset" do
      original = Application.get_env(:nucleus, Scope)
      on_exit(fn -> Application.put_env(:nucleus, Scope, original) end)

      Application.put_env(:nucleus, Scope, [])

      assert Scope.tenant_namespace() == "local"
    end
  end

  describe "verify_provider_at_boot!/0" do
    import ExUnit.CaptureLog

    setup do
      original = Application.get_env(:nucleus, Scope)
      on_exit(fn -> Application.put_env(:nucleus, Scope, original) end)
      :ok
    end

    @tag :unit
    test "warns and names the dev identity when the Disabled provider is configured" do
      Application.put_env(:nucleus, Scope,
        provider: Nucleus.Scope.Provider.Disabled,
        tenant_namespace: "acme"
      )

      log = capture_log(fn -> assert Scope.verify_provider_at_boot!() == :ok end)

      assert log =~ "AUTH DISABLED"
      assert log =~ "tenant -> acme"
    end

    @tag :unit
    test "raises rather than warning when the Cognito provider is configured" do
      Application.put_env(:nucleus, Scope, provider: Nucleus.Scope.Provider.Cognito)

      assert_raise RuntimeError, ~r/AUTH-A01\.\.A11/, fn ->
        Scope.verify_provider_at_boot!()
      end
    end
  end
end
