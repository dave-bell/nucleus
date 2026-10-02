defmodule Nucleus.TenantApi.ServiceToken.Cognito do
  @moduledoc """
  Nucleus's Cognito M2M access token, from the client-credentials grant.

  POSTs `grant_type=client_credentials&scope={COGNITO_SCOPE}` with
  `Authorization: Basic base64(client_id:client_secret)` to
  `https://{COGNITO_DOMAIN}/oauth2/token`. The client is Nucleus-only — created by
  Terraform at deploy time, separate from the sign-in client (`COGNITO_CLIENT_ID`)
  and from the M2M clients tenants create for themselves (`Nucleus.M2M.Clients`).

  ## Configuration

      config :nucleus, #{inspect(__MODULE__)},
        domain: "auth.example.com",     # COGNITO_DOMAIN — a bare host, no scheme
        client_id: "...",               # COGNITO_CLIENT_ID_API
        client_secret: "...",           # COGNITO_CLIENT_SECRET_API
        scope: "tenant/api"             # COGNITO_SCOPE

  Read on every call. Anything missing, or a domain that is not a bare host, is
  `{:error, %Error{kind: :not_configured}}` **with no request attempted** — never
  a crash and never a request to a guessed host. `config/runtime.exs` makes a
  missing value a boot failure when this driver is selected, so this is the
  backstop, not the normal path.

  ## Errors

  | Token endpoint | Kind |
  |---|---|
  | 400, 401 | `:auth_expired` — Cognito rejected Nucleus's own client credentials |
  | 5xx, any other status, transport failure, a body that is not a grant | `:unavailable` |

  Cognito answers a bad client, a bad secret and a bad scope with 400
  (`invalid_client`, `invalid_scope`, ...). All are a problem with Nucleus's own
  credentials, which is what `:auth_expired` means in `Nucleus.Backend.Error`.

  ## Same transport rules as the other HTTP adapters

  `retry: false`, `redirect: false`, separate connect and receive timeouts. A
  redirect would carry the `Authorization: Basic` header — the client secret — to
  whatever host it named.

  ## Never logged

  Only the status, a per-call request id and, on transport failure, the error's
  reason. Not the client secret, not the token, not the response body: an error
  body can echo request parameters, and a success body is the token.
  """

  @behaviour Nucleus.TenantApi.ServiceToken

  require Logger

  alias Nucleus.Backend.Error
  alias Nucleus.TenantApi.ServiceToken

  @path "/oauth2/token"
  @default_connect_timeout_ms 5_000
  @default_receive_timeout_ms 10_000
  # A bare host, optionally with a port. No scheme, no path, no userinfo.
  @bare_host ~r/\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:\d{1,5})?\z/

  @impl ServiceToken
  def request_token do
    request_id = request_id()

    with {:ok, settings} <- settings() do
      case perform(settings, request_id) do
        {:response, 200, body} -> decode(body, request_id)
        {:response, status, _body} when status in [400, 401] -> rejected(status, request_id)
        {:response, status, _body} -> unavailable(status, request_id)
        {:transport_error, exception} -> {:error, transport_error(exception, request_id)}
      end
    end
  end

  @impl ServiceToken
  def health_check do
    # Reachability of the issuer, which a token request answers directly. The
    # token itself is dropped here, not returned.
    with {:ok, _grant} <- request_token(), do: :ok
  end

  defp perform(settings, request_id) do
    request =
      Req.new(
        [
          method: :post,
          url: "https://" <> settings.domain <> @path,
          auth: {:basic, settings.client_id <> ":" <> settings.client_secret},
          form: [grant_type: "client_credentials", scope: settings.scope],
          headers: [{"accept", "application/json"}],
          retry: false,
          redirect: false,
          decode_body: false,
          receive_timeout: timeout(:receive_timeout_ms, @default_receive_timeout_ms),
          connect_options: [timeout: timeout(:connect_timeout_ms, @default_connect_timeout_ms)]
        ] ++ Keyword.take(config(), [:plug])
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.info("service_token POST #{@path} -> #{status} request_id=#{request_id}")
        {:response, status, body}

      {:error, exception} ->
        Logger.warning(
          "service_token POST #{@path} failed: #{transport_reason(exception)} request_id=#{request_id}"
        )

        {:transport_error, exception}
    end
  end

  defp decode(body, request_id) when is_binary(body) do
    with {:ok, %{"access_token" => token, "expires_in" => expires_in}} <- Jason.decode(body),
         true <- is_binary(token) and token != "",
         true <- is_integer(expires_in) and expires_in > 0 do
      {:ok, %{token: token, expires_in: expires_in}}
    else
      # Not the decoder's message, not the body: either could quote the token.
      _malformed -> malformed(request_id)
    end
  end

  defp decode(_body, request_id), do: malformed(request_id)

  defp malformed(request_id) do
    {:error,
     error(:unavailable, "the token endpoint returned something that is not a grant", %{
       request_id: request_id
     })}
  end

  defp rejected(status, request_id) do
    {:error,
     error(:auth_expired, "cognito rejected the tenant API client credentials", %{
       status: status,
       request_id: request_id
     })}
  end

  defp unavailable(status, request_id) do
    {:error,
     error(:unavailable, "the token endpoint answered #{status}", %{
       status: status,
       request_id: request_id
     })}
  end

  defp transport_error(exception, request_id) do
    error(:unavailable, "the token endpoint is unreachable", %{
      reason: transport_reason(exception),
      request_id: request_id
    })
  end

  defp settings do
    config = config()

    with {:ok, domain} <- domain(config[:domain]),
         {:ok, client_id} <- present(config, :client_id, "COGNITO_CLIENT_ID_API"),
         {:ok, client_secret} <- present(config, :client_secret, "COGNITO_CLIENT_SECRET_API"),
         {:ok, scope} <- present(config, :scope, "COGNITO_SCOPE") do
      {:ok, %{domain: domain, client_id: client_id, client_secret: client_secret, scope: scope}}
    end
  end

  defp domain(value) when is_binary(value) do
    domain = String.trim(value)

    if Regex.match?(@bare_host, domain) do
      {:ok, domain}
    else
      {:error,
       error(:not_configured, "COGNITO_DOMAIN must be a bare host, with no scheme or path", %{
         variable: "COGNITO_DOMAIN"
       })}
    end
  end

  defp domain(_absent) do
    {:error, error(:not_configured, "COGNITO_DOMAIN is missing", %{variable: "COGNITO_DOMAIN"})}
  end

  defp present(config, key, variable) do
    case config[key] do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _absent ->
        {:error, error(:not_configured, "#{variable} is missing", %{variable: variable})}
    end
  end

  defp timeout(key, default) do
    case config()[key] do
      ms when is_integer(ms) and ms > 0 -> ms
      _absent_or_invalid -> default
    end
  end

  defp transport_reason(%{reason: reason}), do: inspect(reason)
  defp transport_reason(%module{}), do: inspect(module)
  defp transport_reason(other), do: inspect(other)

  defp request_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp config, do: Application.get_env(:nucleus, __MODULE__, [])

  defp error(kind, message, details) do
    Error.new(kind, ServiceToken.boundary(), message, details)
  end
end
