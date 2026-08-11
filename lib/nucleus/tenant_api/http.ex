defmodule Nucleus.TenantApi.Http do
  @moduledoc """
  The tenant API over HTTP, using `Req`.

  ## The destination is deployment configuration, never a caller's choice

  The base URL comes from `TENANT_API_BASE_URL` and the path is the literal
  `/environment`. No caller input reaches the URL, which is the guarantee
  `PRX-A07` makes: a boundary that could be pointed at an arbitrary host by its
  caller is an SSRF primitive, and this one takes no argument that could do it.

  A missing, blank or unparseable base URL is `{:error, %Error{kind:
  :not_configured}}` **with no request attempted** — never a crash, and never a
  request to some default host.

  ## Failure is prompt and total

  `retry: false`. `SEC-A17` requires a request be rejected outright when
  environment validation is unavailable, and rejection has to be *prompt*: a
  retry ladder turns a clean fail-closed rejection into a LiveView `mount` that
  hangs. Connect and receive timeouts are set explicitly and separately — they
  fail for different reasons, and one knob for both forces one of them wrong.

  `redirect: false`. A redirect is an unexpected response from this API, and
  following one risks carrying the user's `Authorization` header to whatever host
  the redirect names. It maps to `:unavailable` like any other unexpected status.

  ## A bad element fails the whole call

  An element with a missing or blank `shortName` fails the entire request. The
  adapter does not drop it and does not emit an `%Environment{}` without a short
  name — that value builds Parameter Store paths, so a silently absent one is a
  security-adjacent defect rather than a cosmetic one. See
  `Nucleus.TenantApi.Environment.from_api_list/1`.

  ## Never log the token, never log the body

  Only the status, a per-call request identifier, and — on transport failure —
  the error's reason. A response body may contain anything; a token must not be
  written anywhere. The request identifier exists so a user-reported failure can
  be correlated with a log line without either.

  ## Assumed response shape

  A top-level JSON array of objects, per the wiki's Environments contract. This
  is asserted rather than guessed at: an unexpected shape is `:unavailable`, not
  a best-effort parse. If a real tenant API turns out to wrap the list in an
  envelope, `unwrap/1` is the single place that changes.
  """

  @behaviour Nucleus.TenantApi

  require Logger

  alias Nucleus.Backend.Error
  alias Nucleus.TenantApi
  alias Nucleus.TenantApi.Environment

  @path "/environment"
  @default_connect_timeout_ms 5_000
  @default_receive_timeout_ms 10_000

  @impl Nucleus.TenantApi
  def list_environments(token) do
    request_id = request_id()

    case perform(token, request_id) do
      {:response, 200, body} ->
        decode(body, request_id)

      {:response, status, _body} when status in [401, 403] ->
        {:error,
         error(:auth_expired, "the tenant API rejected our credentials", %{
           status: status,
           request_id: request_id
         })}

      # 400, 404, 429, 5xx and anything else. Each has its own cause but the same
      # consequence for a caller: no authoritative environment list exists right
      # now, so `SEC-A17` fails closed. An explicit catch-all, so no status can
      # fall through to incidental behaviour.
      {:response, status, _body} ->
        {:error,
         error(:unavailable, "the tenant API answered #{status}", %{
           status: status,
           request_id: request_id
         })}

      {:transport_error, exception} ->
        {:error, transport_error(exception, request_id)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl Nucleus.TenantApi
  def health_check do
    request_id = request_id()

    # Reachability, not permission. Any status at all means the service answered,
    # so 401 and 403 are healthy — without that, every health check would start
    # failing the moment EN-6 makes anonymous calls unauthorised. The body is
    # discarded undecoded: a malformed list is a listing problem, not an
    # unreachable dependency.
    case perform(nil, request_id) do
      {:response, status, _body} when status >= 500 ->
        {:error,
         error(:unavailable, "the tenant API answered #{status}", %{
           status: status,
           request_id: request_id
         })}

      {:response, _status, _body} ->
        :ok

      {:transport_error, exception} ->
        {:error, transport_error(exception, request_id)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp perform(token, request_id) do
    with {:ok, url} <- url() do
      request =
        Req.new(
          [
            method: :get,
            url: url,
            headers: headers(token),
            retry: false,
            redirect: false,
            decode_body: false,
            receive_timeout: timeout(:receive_timeout_ms, @default_receive_timeout_ms),
            connect_options: [timeout: timeout(:connect_timeout_ms, @default_connect_timeout_ms)]
          ] ++ Keyword.take(config(), [:plug])
        )

      case Req.request(request) do
        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.info("tenant_api GET #{@path} -> #{status} request_id=#{request_id}")
          {:response, status, body}

        {:error, exception} ->
          Logger.warning(
            "tenant_api GET #{@path} failed: #{transport_reason(exception)} request_id=#{request_id}"
          )

          {:transport_error, exception}
      end
    end
  end

  defp decode(body, request_id) do
    with {:ok, decoded} <- json(body, request_id),
         {:ok, list} <- unwrap(decoded, request_id),
         {:ok, environments} <- environments(list, request_id) do
      {:ok, environments}
    end
  end

  defp json(body, request_id) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _error} ->
        # The decoder's message quotes the offending input, so it is deliberately
        # not carried into `details` — that would put the response body in a log.
        {:error,
         error(:unavailable, "the tenant API returned a body that is not JSON", %{
           request_id: request_id
         })}
    end
  end

  defp json(_body, request_id) do
    {:error, error(:unavailable, "the tenant API returned no body", %{request_id: request_id})}
  end

  defp unwrap(list, _request_id) when is_list(list), do: {:ok, list}

  defp unwrap(_other, request_id) do
    {:error,
     error(:unavailable, "the tenant API returned an unexpected shape", %{
       request_id: request_id
     })}
  end

  defp environments(list, request_id) do
    case Environment.from_api_list(list) do
      {:ok, environments} ->
        {:ok, environments}

      {:error, reason} ->
        {:error,
         error(:unavailable, "the tenant API returned an unusable environment", %{
           reason: reason,
           request_id: request_id
         })}
    end
  end

  defp url do
    case config()[:base_url] do
      value when is_binary(value) -> validate_base_url(String.trim(value))
      _absent -> {:error, not_configured()}
    end
  end

  defp validate_base_url(base_url) do
    case URI.new(base_url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, String.trim_trailing(base_url, "/") <> @path}

      _invalid ->
        {:error, not_configured()}
    end
  end

  defp not_configured do
    error(
      :not_configured,
      "TENANT_API_BASE_URL is missing or is not an http(s) URL",
      %{variable: "TENANT_API_BASE_URL"}
    )
  end

  defp headers(token) do
    case token do
      token when is_binary(token) and token != "" ->
        [{"accept", "application/json"}, {"authorization", "Bearer " <> token}]

      _blank_or_nil ->
        # Auth is deferred to EN-6, so an anonymous call is the norm today. Sending
        # a header with an empty token would be worse than sending none.
        [{"accept", "application/json"}]
    end
  end

  defp timeout(key, default) do
    case config()[key] do
      ms when is_integer(ms) and ms > 0 -> ms
      _absent_or_invalid -> default
    end
  end

  defp transport_error(exception, request_id) do
    error(:unavailable, "the tenant API is unreachable", %{
      reason: transport_reason(exception),
      request_id: request_id
    })
  end

  defp transport_reason(%{reason: reason}), do: inspect(reason)
  defp transport_reason(%module{}), do: inspect(module)
  defp transport_reason(other), do: inspect(other)

  defp request_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp config, do: Application.get_env(:nucleus, __MODULE__, [])

  defp error(kind, message, details) do
    Error.new(kind, TenantApi.boundary(), message, details)
  end
end
