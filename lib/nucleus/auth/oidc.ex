defmodule Nucleus.Auth.OIDC do
  @moduledoc """
  The Cognito Hosted UI sign-in protocol (`AUTH-A02`, `AUTH-A04`): the pure
  protocol steps, with no session, plug or process of its own.

  1. `authorization_request/0` builds the redirect to the Hosted UI - an
     Authorization Code request carrying a random `state`, a random `nonce`
     and a PKCE `code_challenge` (S256).
  2. `exchange_code/2` trades the returned code for tokens at the token
     endpoint, as a confidential client (the secret travels in an
     `Authorization: Basic` header, server to server, never to the browser).
  3. `verify_id_token/2` checks the ID token's signature against the pool's
     JWKS, then `iss`, `aud`, `token_use`, `exp` and `nonce`.
  4. `authorized?/1` checks `cognito:groups` for the tenant's allowed group.

  ## No token leaves this module

  `exchange_code/2` returns only the ID token, never the access or refresh
  token Cognito also sends, and the caller keeps only claims from the verified
  ID token (`user/1`). Nucleus has no use for the others: no backend is called
  with a user's credential (`docs/adr/0038-session-based-authentication-no-token-passthrough.md`)
  and the sign-in request asks for `openid email` only, no API scope
  (`docs/adr/0039-tenant-api-service-credential.md`).

  ## Why `state` and `nonce` are both here

  They defend different things. `state` ties the callback to the browser that
  started the sign-in (login CSRF); it is checked by the caller against the
  value stored in the session. `nonce` ties the ID token to the authorization
  request that produced it (token replay); it is checked here, inside the
  signed token. PKCE binds the code to the client that asked for it.

  ## Cognito-specific, deliberately

  Endpoint URLs and the `token_use` and `cognito:*` claims are Cognito's. They
  are confined to this module and `Nucleus.Auth.Config`, so changing identity
  provider means changing those two files and nothing that calls them.
  """

  alias Nucleus.Auth.Config

  @scope "openid email"
  @jwks_key {__MODULE__, :jwks}
  @clock_skew_seconds 60
  @receive_timeout 5_000

  @type claims :: %{optional(String.t()) => term()}

  @type request :: %{
          url: String.t(),
          state: String.t(),
          nonce: String.t(),
          code_verifier: String.t()
        }

  @doc """
  Builds the Hosted UI authorize URL and the three secrets the callback must
  be able to check later.

  The URL names the corporate identity provider (`identity_provider`), so
  Cognito redirects silently to it instead of showing its own provider-chooser
  page. Cognito still federates and issues the token.

  The caller stores `:state`, `:nonce` and `:code_verifier` in the session and
  redirects the browser to `:url`.
  """
  @spec authorization_request() :: request()
  def authorization_request do
    state = random_token()
    nonce = random_token()
    code_verifier = random_token()

    query =
      URI.encode_query(
        response_type: "code",
        client_id: Config.client_id(),
        redirect_uri: Config.redirect_uri(),
        scope: @scope,
        identity_provider: Config.identity_provider(),
        state: state,
        nonce: nonce,
        code_challenge: code_challenge(code_verifier),
        code_challenge_method: "S256"
      )

    %{
      url: Config.authorize_url() <> "?" <> query,
      state: state,
      nonce: nonce,
      code_verifier: code_verifier
    }
  end

  @doc """
  Exchanges an authorization `code` for tokens and returns the raw ID token.

  Errors, none of which carry the response body (it can hold tokens):

  - `{:error, {:token_endpoint, status}}` - Cognito answered with a non-200.
  - `{:error, :token_endpoint_unreachable}` - transport failure or timeout.
  - `{:error, :no_id_token}` - a 200 with no `id_token` in it.
  """
  @spec exchange_code(String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, {:token_endpoint, integer()} | :token_endpoint_unreachable | :no_id_token}
  def exchange_code(code, code_verifier) do
    request =
      Req.new(
        url: Config.token_url(),
        method: :post,
        auth: {:basic, "#{Config.client_id()}:#{Config.client_secret()}"},
        form: [
          grant_type: "authorization_code",
          client_id: Config.client_id(),
          code: code,
          redirect_uri: Config.redirect_uri(),
          code_verifier: code_verifier
        ],
        retry: false,
        receive_timeout: @receive_timeout
      )

    case Req.request(request, Config.req_options()) do
      {:ok, %Req.Response{status: 200, body: %{"id_token" => id_token}}}
      when is_binary(id_token) ->
        {:ok, id_token}

      {:ok, %Req.Response{status: 200}} ->
        {:error, :no_id_token}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:token_endpoint, status}}

      {:error, _exception} ->
        {:error, :token_endpoint_unreachable}
    end
  end

  @doc """
  Verifies `jwt` and returns its claims.

  Order matters: the signature is checked before any claim is trusted. Only
  RS256 is accepted (`verify_strict`), so a token cannot pick its own
  algorithm - `alg: none` and HMAC-with-the-public-key downgrades both fail.

  Errors: `:malformed`, `:unknown_key`, `:jwks_unavailable`,
  `:invalid_signature`, `:invalid_issuer`, `:invalid_audience`,
  `:wrong_token_use`, `:expired`, `:nonce_mismatch`.
  """
  @spec verify_id_token(String.t(), String.t()) :: {:ok, claims()} | {:error, atom()}
  def verify_id_token(jwt, expected_nonce) when is_binary(jwt) and is_binary(expected_nonce) do
    with {:ok, kid} <- key_id(jwt),
         {:ok, jwk} <- signing_key(kid),
         {:ok, claims} <- verify_signature(jwk, jwt) do
      check_claims(claims, expected_nonce)
    end
  end

  @doc "Whether the ID token's `cognito:groups` claim contains the tenant's allowed group."
  @spec authorized?(claims()) :: boolean()
  def authorized?(claims) do
    case Map.get(claims, "cognito:groups") do
      groups when is_list(groups) -> Config.allowed_group() in groups
      _ -> false
    end
  end

  @doc """
  The identity to keep from a verified ID token. `email` is always present on
  an ID token for the `email` scope; `username` is Cognito's `cognito:username`.
  """
  @spec user(claims()) :: %{email: String.t() | nil, username: String.t() | nil}
  def user(claims) do
    %{email: claims["email"], username: claims["cognito:username"]}
  end

  @doc "Drops the cached signing keys. Tests only; a rotation is handled by `signing_key/1` itself."
  @spec clear_jwks_cache() :: :ok
  def clear_jwks_cache do
    :persistent_term.erase(@jwks_key)
    :ok
  end

  # --- tokens ---------------------------------------------------------------

  defp random_token, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp code_challenge(verifier) do
    :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)
  end

  # --- signature ------------------------------------------------------------

  defp key_id(jwt) do
    with {:ok, header} <- decode_header(jwt),
         kid when is_binary(kid) <- header["kid"] do
      {:ok, kid}
    else
      _ -> {:error, :malformed}
    end
  end

  defp decode_header(jwt) do
    case String.split(jwt, ".") do
      [header, _payload, _signature] ->
        with {:ok, json} <- Base.url_decode64(header, padding: false),
             {:ok, %{} = decoded} <- Jason.decode(json) do
          {:ok, decoded}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp verify_signature(jwk, jwt) do
    case JOSE.JWS.verify_strict(jwk, ["RS256"], jwt) do
      {true, payload, _jws} ->
        case Jason.decode(payload) do
          {:ok, %{} = claims} -> {:ok, claims}
          _ -> {:error, :malformed}
        end

      _ ->
        {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  # The cached keys first; an unknown `kid` means the pool may have rotated its
  # keys, so refetch exactly once before giving up.
  defp signing_key(kid) do
    case find_key(cached_jwks(), kid) do
      {:ok, jwk} ->
        {:ok, jwk}

      :error ->
        with {:ok, keys} <- fetch_jwks() do
          :persistent_term.put(@jwks_key, keys)

          case find_key(keys, kid) do
            {:ok, jwk} -> {:ok, jwk}
            :error -> {:error, :unknown_key}
          end
        end
    end
  end

  defp cached_jwks, do: :persistent_term.get(@jwks_key, [])

  defp find_key(keys, kid) do
    case Enum.find(keys, &(&1["kid"] == kid)) do
      nil -> :error
      key -> {:ok, JOSE.JWK.from_map(key)}
    end
  end

  defp fetch_jwks do
    request = Req.new(url: Config.jwks_url(), retry: false, receive_timeout: @receive_timeout)

    case Req.request(request, Config.req_options()) do
      {:ok, %Req.Response{status: 200, body: %{"keys" => keys}}} when is_list(keys) ->
        {:ok, keys}

      _ ->
        {:error, :jwks_unavailable}
    end
  end

  # --- claims ---------------------------------------------------------------

  defp check_claims(claims, expected_nonce) do
    now = System.system_time(:second)

    cond do
      claims["iss"] != Config.issuer() -> {:error, :invalid_issuer}
      claims["aud"] != Config.client_id() -> {:error, :invalid_audience}
      claims["token_use"] != "id" -> {:error, :wrong_token_use}
      not expired_ok?(claims["exp"], now) -> {:error, :expired}
      not nonce_ok?(claims["nonce"], expected_nonce) -> {:error, :nonce_mismatch}
      true -> {:ok, claims}
    end
  end

  # A missing or non-numeric `exp` is not "never expires".
  defp expired_ok?(exp, now) when is_number(exp), do: exp + @clock_skew_seconds > now
  defp expired_ok?(_exp, _now), do: false

  defp nonce_ok?(nonce, expected) when is_binary(nonce) do
    Plug.Crypto.secure_compare(nonce, expected)
  end

  defp nonce_ok?(_nonce, _expected), do: false
end
