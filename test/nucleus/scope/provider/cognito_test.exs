defmodule Nucleus.Scope.Provider.CognitoTest do
  use ExUnit.Case, async: true

  alias Nucleus.Scope.Provider.Cognito

  @tag :unit
  test "raises with a message pointing at AUTH-A01..A11" do
    error = assert_raise RuntimeError, fn -> Cognito.build(%{}) end

    assert error.message =~ "Real authentication is not implemented"
    assert error.message =~ "AUTH-A01..A11"
  end

  @tag :unit
  test "raises regardless of context" do
    assert_raise RuntimeError, fn -> Cognito.build(%{source_ip: "1.2.3.4", token: "fake"}) end
  end
end
