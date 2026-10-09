defmodule Nucleus.AuthFixtures do
  @moduledoc """
  Test doubles for the Cognito sign-in flow (AUTH-S1): sign-in settings, an RSA
  signing key standing in for the pool's, ID tokens signed with it, and a
  `Req.Test` stub for the token and JWKS endpoints - the layer
  `docs/requirements/Test-Strategy.md` prescribes, since the real Hosted UI
  round-trip is a manual/staging check.

  `put_auth_config/1` mutates application env, so every case using it must be
  `async: false`; it restores the previous value on exit.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @stub Nucleus.Auth.Cognito
  @region "eu-west-1"
  @pool "eu-west-1_testpool"
  @client_id "test-client-id"
  @client_secret "test-client-secret"
  @group "nucleus-users"
  @identity_provider "Corp"

  def client_id, do: @client_id
  def client_secret, do: @client_secret
  def allowed_group, do: @group
  def identity_provider, do: @identity_provider
  def issuer, do: "https://cognito-idp.#{@region}.amazonaws.com/#{@pool}"

  @doc "Installs the full set of sign-in settings, with the Req stub, for one test."
  def put_auth_config(overrides \\ []) do
    previous = Application.get_env(:nucleus, Nucleus.Auth)

    Application.put_env(
      :nucleus,
      Nucleus.Auth,
      Keyword.merge(
        [
          domain: "auth.example.test",
          region: @region,
          user_pool_id: @pool,
          client_id: @client_id,
          client_secret: @client_secret,
          allowed_group: @group,
          identity_provider: @identity_provider,
          req_options: [plug: {Req.Test, @stub}]
        ],
        overrides
      )
    )

    Nucleus.Auth.OIDC.clear_jwks_cache()

    on_exit(fn ->
      Nucleus.Auth.OIDC.clear_jwks_cache()

      case previous do
        nil -> Application.delete_env(:nucleus, Nucleus.Auth)
        value -> Application.put_env(:nucleus, Nucleus.Auth, value)
      end
    end)

    :ok
  end

  @doc "A fresh RSA key with a key id."
  def generate_key(kid \\ "test-key-1") do
    {kid, JOSE.JWK.generate_key({:rsa, 2048})}
  end

  @doc "The JWKS document (public halves only) for `keys`."
  def jwks(keys) do
    %{
      "keys" =>
        for {kid, jwk} <- keys do
          {_, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
          Map.merge(public, %{"kid" => kid, "alg" => "RS256", "use" => "sig"})
        end
    }
  end

  @doc "Claims for a valid ID token, with `overrides` merged over them."
  def claims(overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "iss" => issuer(),
        "aud" => @client_id,
        "token_use" => "id",
        "sub" => "sub-123",
        "email" => "ada@example.com",
        "cognito:username" => "ada",
        "cognito:groups" => [@group],
        "iat" => now,
        "exp" => now + 3600,
        "nonce" => "the-nonce"
      },
      overrides
    )
  end

  @doc "Signs `claims` as an RS256 JWT with `key`."
  def sign({kid, jwk}, claims, header \\ %{}) do
    header = Map.merge(%{"alg" => "RS256", "kid" => kid, "typ" => "JWT"}, header)
    {_, jwt} = jwk |> JOSE.JWT.sign(header, claims) |> JOSE.JWS.compact()
    jwt
  end

  @doc """
  Stubs Cognito's two endpoints for the current test.

  Options:

  - `:keys` - `[{kid, jwk}]` served as the JWKS (default `[]`)
  - `:token` - what the token endpoint answers: `{:ok, id_token}`,
    `{:status, integer}`, `{:body, map}` or `:transport_error`

  The test process receives `{:token_request, form_params, authorization_header}`
  for each token call and `:jwks_request` for each JWKS fetch.
  """
  def stub_cognito(opts) do
    test = self()
    keys = Keyword.get(opts, :keys, [])
    token = Keyword.get(opts, :token, {:status, 500})
    jwks_path = "/#{@pool}/.well-known/jwks.json"

    Req.Test.stub(@stub, fn
      %Plug.Conn{request_path: "/oauth2/token"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        authorization = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
        send(test, {:token_request, URI.decode_query(body), authorization})

        case token do
          {:ok, id_token} ->
            Req.Test.json(conn, %{
              "id_token" => id_token,
              "access_token" => "must-never-be-kept",
              "refresh_token" => "must-never-be-kept",
              "token_type" => "Bearer"
            })

          {:body, map} ->
            Req.Test.json(conn, map)

          {:status, status} ->
            conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"error" => "invalid_grant"})

          :transport_error ->
            Req.Test.transport_error(conn, :econnrefused)
        end

      %Plug.Conn{request_path: ^jwks_path} = conn ->
        send(test, :jwks_request)
        Req.Test.json(conn, jwks(keys))
    end)
  end
end
