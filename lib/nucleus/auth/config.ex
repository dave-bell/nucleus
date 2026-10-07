defmodule Nucleus.Auth.Config do
  @moduledoc """
  Sign-in and session-lifetime settings (AUTH-S1).

  Everything lives under `config :nucleus, Nucleus.Auth`, populated by
  `config/runtime.exs`:

  | Key | Env var | |
  |---|---|---|
  | `:domain` | `COGNITO_DOMAIN` | Hosted UI host, **no scheme** |
  | `:region` | `COGNITO_REGION` | |
  | `:user_pool_id` | `COGNITO_USER_POOL_ID` | |
  | `:client_id` | `COGNITO_CLIENT_ID` | the sign-in client, not the `_API` M2M one |
  | `:client_secret` | `COGNITO_CLIENT_SECRET` | server-side only |
  | `:allowed_group` | `COGNITO_ALLOWED_GROUP` | `cognito:groups` must contain it |
  | `:identity_provider` | `COGNITO_IDENTITY_PROVIDER` | the IdP's name in the pool; the authorize request names it so Cognito skips its chooser page |
  | `:idle_timeout` | `SESSION_IDLE_TIMEOUT` | seconds, default 900 |
  | `:max_age` | `SESSION_MAX_AGE` | seconds, default 28800 |

  The Cognito keys are only set when `AUTH_ENABLED=true`; `verify!/0` is the
  boot check that proves they all arrived. The two timeouts have defaults here
  so a fresh clone, and every test, needs no configuration for them.

  Every Cognito-specific URL is derived in this module and `Nucleus.Auth.OIDC`
  and nowhere else, so a change of identity provider is a change to those two.
  """

  @cognito_keys [
    :domain,
    :region,
    :user_pool_id,
    :client_id,
    :client_secret,
    :allowed_group,
    :identity_provider
  ]

  @default_idle_timeout 15 * 60
  @default_max_age 8 * 60 * 60
  @default_activity_throttle_ms 30_000

  @doc "Raises unless every sign-in setting is present. Called at boot when `AUTH_ENABLED=true`."
  @spec verify!() :: :ok
  def verify! do
    config = env()

    case Enum.filter(@cognito_keys, &blank?(Keyword.get(config, &1))) do
      [] ->
        :ok

      missing ->
        raise "Nucleus.Auth is not configured: missing " <>
                Enum.map_join(missing, ", ", &inspect/1) <>
                " (set the COGNITO_* variables, see docs/requirements/Platform-Operations.md)"
    end
  end

  @doc "Seconds a session may go without activity."
  @spec idle_timeout() :: pos_integer()
  def idle_timeout, do: Keyword.get(env(), :idle_timeout, @default_idle_timeout)

  @doc "Seconds a session may live since sign-in, regardless of activity."
  @spec max_age() :: pos_integer()
  def max_age, do: Keyword.get(env(), :max_age, @default_max_age)

  @doc """
  The least time between two `handle_event`-driven activity reports from one
  tab, in milliseconds. A form field fires an event per keystroke; against a
  15-minute idle limit, reporting more than twice a minute buys nothing.
  """
  @spec activity_throttle_ms() :: non_neg_integer()
  def activity_throttle_ms,
    do: Keyword.get(env(), :activity_throttle_ms, @default_activity_throttle_ms)

  @spec client_id() :: String.t()
  def client_id, do: fetch!(:client_id)

  @spec client_secret() :: String.t()
  def client_secret, do: fetch!(:client_secret)

  @spec allowed_group() :: String.t()
  def allowed_group, do: fetch!(:allowed_group)

  @spec identity_provider() :: String.t()
  def identity_provider, do: fetch!(:identity_provider)

  @doc "The Hosted UI authorize endpoint."
  @spec authorize_url() :: String.t()
  def authorize_url, do: "https://#{fetch!(:domain)}/oauth2/authorize"

  @doc "The Hosted UI token endpoint."
  @spec token_url() :: String.t()
  def token_url, do: "https://#{fetch!(:domain)}/oauth2/token"

  @doc "The `iss` claim every ID token from this pool carries."
  @spec issuer() :: String.t()
  def issuer, do: "https://cognito-idp.#{fetch!(:region)}.amazonaws.com/#{fetch!(:user_pool_id)}"

  @doc "The pool's public signing keys."
  @spec jwks_url() :: String.t()
  def jwks_url, do: issuer() <> "/.well-known/jwks.json"

  @doc """
  The callback URL registered on the sign-in app client.

  Built from the endpoint's own URL, so it follows each environment:
  `https://{PHX_HOST}/auth/callback` in production,
  `http://localhost:4000/auth/callback` in dev. The same value must be sent
  on the authorize request and on the token exchange.
  """
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: NucleusWeb.Endpoint.url() <> "/auth/callback"

  @doc """
  Extra options merged into every outbound `Req` request, so tests can install a
  `Req.Test` stub with `config :nucleus, Nucleus.Auth, req_options: [plug: ...]`.
  """
  @spec req_options() :: keyword()
  def req_options, do: Keyword.get(env(), :req_options, [])

  defp fetch!(key) do
    case Keyword.get(env(), key) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "Nucleus.Auth is not configured: missing #{inspect(key)}"
    end
  end

  defp blank?(value), do: value in [nil, ""]

  defp env, do: Application.get_env(:nucleus, Nucleus.Auth, [])
end
