defmodule Nucleus.Scope.Provider.CognitoTest do
  use ExUnit.Case, async: true

  alias Nucleus.Auth.Session
  alias Nucleus.Scope
  alias Nucleus.Scope.Provider.Cognito

  @session %Session{
    id: "sid",
    email: "ada@example.com",
    username: "ada",
    signed_in_at: 1,
    last_active: 1
  }

  @tag :unit
  @tag action: "AUTH-A02"
  test "builds the scope from the session's identity" do
    assert {:ok, %Scope{} = scope} = Cognito.build(%{session: @session, source_ip: "1.2.3.4"})

    assert scope.user == %{email: "ada@example.com", username: "ada"}
    assert scope.source_ip == "1.2.3.4"
    assert scope.tenant == Scope.tenant_namespace()
    assert Scope.authenticated?(scope)
    assert Scope.audit_user(scope) == "ada@example.com"
  end

  @tag :unit
  test "grants no access scopes: sign-in requests none" do
    assert {:ok, %Scope{scopes: []}} = Cognito.build(%{session: @session})
  end

  @tag :unit
  test "has no token to carry" do
    assert {:ok, scope} = Cognito.build(%{session: @session})
    refute Map.has_key?(scope, :token)
  end

  @tag :unit
  test "without a session there is no identity to invent" do
    assert Cognito.build(%{}) == {:error, :no_session}
    assert Cognito.build(%{source_ip: "1.2.3.4"}) == {:error, :no_session}
    assert Cognito.build(%{session: nil}) == {:error, :no_session}
  end
end
