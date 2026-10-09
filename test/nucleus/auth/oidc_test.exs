defmodule Nucleus.Auth.OIDCTest do
  use ExUnit.Case, async: false

  import Nucleus.AuthFixtures

  alias Nucleus.Auth.OIDC

  setup do
    put_auth_config()
    key = generate_key("key-1")
    {:ok, key: key}
  end

  describe "authorization_request/0" do
    @describetag action: "AUTH-A02"

    test "targets the Hosted UI authorize endpoint with the code flow, state, nonce and S256 PKCE" do
      request = OIDC.authorization_request()
      uri = URI.parse(request.url)
      query = URI.decode_query(uri.query)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" ==
               "https://auth.example.test/oauth2/authorize"

      assert query["response_type"] == "code"
      assert query["client_id"] == client_id()
      assert query["redirect_uri"] =~ "/auth/callback"
      assert query["scope"] == "openid email"
      assert query["state"] == request.state
      assert query["nonce"] == request.nonce
      assert query["code_challenge_method"] == "S256"

      expected =
        :sha256 |> :crypto.hash(request.code_verifier) |> Base.url_encode64(padding: false)

      assert query["code_challenge"] == expected
    end

    test "never puts the client secret or the verifier in the URL" do
      request = OIDC.authorization_request()

      refute request.url =~ client_secret()
      refute request.url =~ request.code_verifier
    end

    test "generates fresh random values every time" do
      a = OIDC.authorization_request()
      b = OIDC.authorization_request()

      refute a.state == b.state
      refute a.nonce == b.nonce
      refute a.code_verifier == b.code_verifier
      refute a.state == a.nonce
    end

    test "requests no API scope" do
      query =
        OIDC.authorization_request().url
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()

      assert query["scope"] |> String.split() |> Enum.sort() == ["email", "openid"]
    end
  end

  describe "exchange_code/2" do
    @describetag action: "AUTH-A02"

    test "posts the code as a confidential client and returns only the ID token", %{key: key} do
      id_token = sign(key, claims())
      stub_cognito(keys: [key], token: {:ok, id_token})

      assert OIDC.exchange_code("the-code", "the-verifier") == {:ok, id_token}

      assert_received {:token_request, form, authorization}
      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "the-code"
      assert form["code_verifier"] == "the-verifier"
      assert form["redirect_uri"] =~ "/auth/callback"
      assert authorization == "Basic " <> Base.encode64("#{client_id()}:#{client_secret()}")
      refute Map.has_key?(form, "client_secret")
    end

    test "reports a non-200 from the token endpoint" do
      stub_cognito(token: {:status, 400})
      assert OIDC.exchange_code("c", "v") == {:error, {:token_endpoint, 400}}
    end

    test "reports an unreachable token endpoint" do
      stub_cognito(token: :transport_error)
      assert OIDC.exchange_code("c", "v") == {:error, :token_endpoint_unreachable}
    end

    test "reports a 200 with no ID token" do
      stub_cognito(token: {:body, %{"access_token" => "x"}})
      assert OIDC.exchange_code("c", "v") == {:error, :no_id_token}
    end
  end

  describe "verify_id_token/2" do
    @describetag action: "AUTH-A02"

    setup %{key: key} do
      stub_cognito(keys: [key])
      :ok
    end

    test "accepts a correctly signed token and returns its claims", %{key: key} do
      jwt = sign(key, claims())
      assert {:ok, %{"email" => "ada@example.com"}} = OIDC.verify_id_token(jwt, "the-nonce")
    end

    test "rejects a token signed by a different key", %{key: _key} do
      other = generate_key("key-1")
      jwt = sign(other, claims())
      assert OIDC.verify_id_token(jwt, "the-nonce") == {:error, :invalid_signature}
    end

    test "rejects alg none", %{key: _key} do
      payload = claims() |> Jason.encode!() |> Base.url_encode64(padding: false)

      header =
        %{"alg" => "none", "kid" => "key-1"}
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      assert OIDC.verify_id_token("#{header}.#{payload}.", "the-nonce") ==
               {:error, :invalid_signature}
    end

    test "rejects a tampered payload", %{key: key} do
      [header, _payload, signature] = key |> sign(claims()) |> String.split(".")

      forged =
        claims(%{"email" => "mallory@example.com"})
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      assert OIDC.verify_id_token("#{header}.#{forged}.#{signature}", "the-nonce") ==
               {:error, :invalid_signature}
    end

    test "rejects malformed input" do
      assert OIDC.verify_id_token("garbage", "n") == {:error, :malformed}
      assert OIDC.verify_id_token("a.b.c", "n") == {:error, :malformed}
    end

    test "rejects a token with no key id", %{key: {_kid, jwk}} do
      jwt = sign({"key-1", jwk}, claims(), %{"kid" => nil})
      assert OIDC.verify_id_token(jwt, "the-nonce") == {:error, :malformed}
    end

    test "rejects a wrong issuer", %{key: key} do
      jwt = sign(key, claims(%{"iss" => "https://evil.example.com"}))
      assert OIDC.verify_id_token(jwt, "the-nonce") == {:error, :invalid_issuer}
    end

    test "rejects a wrong audience", %{key: key} do
      jwt = sign(key, claims(%{"aud" => "someone-elses-client"}))
      assert OIDC.verify_id_token(jwt, "the-nonce") == {:error, :invalid_audience}
    end

    test "rejects an access token presented as an ID token", %{key: key} do
      jwt = sign(key, claims(%{"token_use" => "access"}))
      assert OIDC.verify_id_token(jwt, "the-nonce") == {:error, :wrong_token_use}
    end

    test "rejects an expired token", %{key: key} do
      jwt = sign(key, claims(%{"exp" => System.system_time(:second) - 3600}))
      assert OIDC.verify_id_token(jwt, "the-nonce") == {:error, :expired}
    end

    test "treats a missing exp as expired, not eternal", %{key: key} do
      jwt = sign(key, Map.delete(claims(), "exp"))
      assert OIDC.verify_id_token(jwt, "the-nonce") == {:error, :expired}
    end

    test "rejects a nonce that does not match the one sent", %{key: key} do
      jwt = sign(key, claims(%{"nonce" => "a-replayed-nonce"}))
      assert OIDC.verify_id_token(jwt, "the-nonce") == {:error, :nonce_mismatch}
    end

    test "rejects a token with no nonce", %{key: key} do
      jwt = sign(key, Map.delete(claims(), "nonce"))
      assert OIDC.verify_id_token(jwt, "the-nonce") == {:error, :nonce_mismatch}
    end
  end

  describe "signing keys" do
    @describetag action: "AUTH-A02"

    test "are cached across verifications", %{key: key} do
      stub_cognito(keys: [key])
      jwt = sign(key, claims())

      assert {:ok, _} = OIDC.verify_id_token(jwt, "the-nonce")
      assert {:ok, _} = OIDC.verify_id_token(jwt, "the-nonce")

      assert_received :jwks_request
      refute_received :jwks_request
    end

    test "are refetched once when a token names an unknown key id (rotation)", %{key: key} do
      stub_cognito(keys: [key])
      assert {:ok, _} = OIDC.verify_id_token(sign(key, claims()), "the-nonce")
      assert_received :jwks_request

      rotated = generate_key("key-2")
      stub_cognito(keys: [key, rotated])

      assert {:ok, _} = OIDC.verify_id_token(sign(rotated, claims()), "the-nonce")
      assert_received :jwks_request
    end

    test "an unknown key id that is still unknown after the refetch is rejected", %{key: key} do
      stub_cognito(keys: [key])
      stranger = generate_key("never-published")

      assert OIDC.verify_id_token(sign(stranger, claims()), "the-nonce") == {:error, :unknown_key}
      assert_received :jwks_request
      refute_received :jwks_request
    end

    test "an unreachable JWKS endpoint is reported, not raised" do
      Req.Test.stub(Nucleus.Auth.Cognito, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      jwt = sign(generate_key("key-1"), claims())

      assert OIDC.verify_id_token(jwt, "the-nonce") == {:error, :jwks_unavailable}
    end
  end

  describe "authorized?/1" do
    @describetag action: "AUTH-A04"

    test "is true when cognito:groups contains the allowed group" do
      assert OIDC.authorized?(claims(%{"cognito:groups" => ["other", allowed_group()]}))
    end

    test "is false when the allowed group is absent" do
      refute OIDC.authorized?(claims(%{"cognito:groups" => ["other"]}))
    end

    test "is false when the claim is missing or not a list" do
      refute OIDC.authorized?(Map.delete(claims(), "cognito:groups"))
      refute OIDC.authorized?(claims(%{"cognito:groups" => allowed_group()}))
    end
  end

  describe "user/1" do
    test "keeps only the email and username from the ID token" do
      assert OIDC.user(claims()) == %{email: "ada@example.com", username: "ada"}
    end
  end
end
