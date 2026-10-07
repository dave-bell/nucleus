defmodule Nucleus.Auth.ConfigTest do
  use ExUnit.Case, async: false

  alias Nucleus.Auth.Config

  @full [
    domain: "auth.example.com",
    region: "eu-west-1",
    user_pool_id: "eu-west-1_abc",
    client_id: "cid",
    client_secret: "shh",
    allowed_group: "nucleus-users"
  ]

  setup do
    previous = Application.get_env(:nucleus, Nucleus.Auth)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(:nucleus, Nucleus.Auth)
  defp restore(value), do: Application.put_env(:nucleus, Nucleus.Auth, value)

  test "verify!/0 passes with every setting present" do
    Application.put_env(:nucleus, Nucleus.Auth, @full)
    assert Config.verify!() == :ok
  end

  test "verify!/0 names every missing setting" do
    Application.put_env(:nucleus, Nucleus.Auth, Keyword.drop(@full, [:client_secret, :domain]))

    error = assert_raise RuntimeError, fn -> Config.verify!() end
    assert error.message =~ ":domain"
    assert error.message =~ ":client_secret"
  end

  test "verify!/0 treats a blank value as missing" do
    Application.put_env(:nucleus, Nucleus.Auth, Keyword.put(@full, :allowed_group, ""))
    assert_raise RuntimeError, ~r/:allowed_group/, fn -> Config.verify!() end
  end

  test "session timeouts default to 15 minutes idle and 8 hours max age" do
    Application.delete_env(:nucleus, Nucleus.Auth)
    assert Config.idle_timeout() == 900
    assert Config.max_age() == 28_800
  end

  test "session timeouts can be overridden, in seconds" do
    Application.put_env(:nucleus, Nucleus.Auth, idle_timeout: 60, max_age: 120)
    assert Config.idle_timeout() == 60
    assert Config.max_age() == 120
  end

  test "endpoints are derived from the domain, region and pool" do
    Application.put_env(:nucleus, Nucleus.Auth, @full)

    assert Config.authorize_url() == "https://auth.example.com/oauth2/authorize"
    assert Config.token_url() == "https://auth.example.com/oauth2/token"
    assert Config.issuer() == "https://cognito-idp.eu-west-1.amazonaws.com/eu-west-1_abc"
    assert Config.jwks_url() == Config.issuer() <> "/.well-known/jwks.json"
    assert Config.redirect_uri() =~ ~r{^https?://.+/auth/callback$}
  end
end
