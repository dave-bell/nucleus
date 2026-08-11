defmodule Nucleus.Scope.Provider.DisabledTest do
  use ExUnit.Case, async: false

  alias Nucleus.Scope
  alias Nucleus.Scope.Provider.Disabled

  setup do
    original_scope = Application.get_env(:nucleus, Scope)
    original_disabled = Application.get_env(:nucleus, Disabled)

    on_exit(fn ->
      Application.put_env(:nucleus, Scope, original_scope)
      Application.put_env(:nucleus, Disabled, original_disabled)
    end)

    :ok
  end

  @tag :unit
  test "builds a scope from the configured dev identity and tenant_namespace" do
    Application.put_env(:nucleus, Scope, tenant_namespace: "acme")
    Application.put_env(:nucleus, Disabled, email: "carol@example.com", scopes: ["read"])

    assert {:ok, scope} = Disabled.build(%{source_ip: "1.2.3.4"})

    assert %Scope{
             user: %{email: "carol@example.com", username: nil},
             tenant: "acme",
             scopes: ["read"],
             source_ip: "1.2.3.4"
           } = scope
  end

  @tag :unit
  test "token is always nil" do
    assert {:ok, scope} = Disabled.build(%{})

    assert scope.token == nil
  end

  @tag :unit
  test "falls back to a default email and empty scopes when unconfigured" do
    Application.put_env(:nucleus, Disabled, [])

    assert {:ok, scope} = Disabled.build(%{})

    assert scope.user.email == "dev@example.com"
    assert scope.scopes == []
  end

  @tag :unit
  test "never returns an error, regardless of context" do
    assert {:ok, %Scope{}} = Disabled.build(%{})
    assert {:ok, %Scope{}} = Disabled.build(%{source_ip: nil})
    assert {:ok, %Scope{}} = Disabled.build(%{anything: "goes"})
  end
end
