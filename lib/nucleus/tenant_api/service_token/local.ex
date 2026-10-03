defmodule Nucleus.TenantApi.ServiceToken.Local do
  @moduledoc """
  The `:service_token` boundary with no identity provider behind it: returns a
  canned token.

  This is what lets dev and test exercise exactly the production code path. The
  cache in `Nucleus.TenantApi.ServiceToken` asks a driver for a token on a miss
  and holds it; it does not know which driver answered. The canned value is
  passed down to `Nucleus.TenantApi.Local` or a test double, which ignore it.

  The token is not a secret and is not a real credential. It lasts an hour so
  that a developer is not refetching constantly; tests move the cache's clock
  rather than waiting.

  Deliberately does not apply `Nucleus.Backend.Faults`. `LOCAL_FORCE_ERROR` is a
  node-wide variable that every local boundary would obey, so applying it here
  would make a fault aimed at `:tenant_api` surface as a `:service_token` error
  and hide the boundary under test.
  """

  @behaviour Nucleus.TenantApi.ServiceToken

  @token "local-service-token"
  @expires_in 3_600

  @doc """
  The canned token this driver returns.
  """
  @spec token() :: String.t()
  def token, do: @token

  @impl Nucleus.TenantApi.ServiceToken
  def request_token, do: {:ok, %{token: @token, expires_in: @expires_in}}

  @impl Nucleus.TenantApi.ServiceToken
  def health_check, do: :ok
end
