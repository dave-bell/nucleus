defmodule Nucleus.TenantApi.ServiceToken.LocalTest do
  # LOCAL_FORCE_ERROR is a node-wide environment variable.
  use ExUnit.Case, async: false

  alias Nucleus.TenantApi.ServiceToken.Local

  test "hands out the canned token, good for an hour" do
    assert Local.request_token() ==
             {:ok, %{token: Local.token(), expires_in: 3_600}}
  end

  test "is always healthy" do
    assert Local.health_check() == :ok
  end

  test "ignores LOCAL_FORCE_ERROR, so a fault aimed at another boundary stays there" do
    System.put_env("LOCAL_FORCE_ERROR", "unavailable")
    on_exit(fn -> System.delete_env("LOCAL_FORCE_ERROR") end)

    assert {:ok, %{token: _token}} = Local.request_token()
  end
end
