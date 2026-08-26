defmodule Nucleus.Nomad.Transport do
  @moduledoc """
  Shared `Req`-based transport for every Nomad HTTP API boundary.

  Deliberately its own module, not folded into `Nucleus.NomadJobs.Http` — Data
  Export (`docs/requirements/Data-Export-Configuration.md`) needs Nomad
  *Variables* under a different boundary (`:nomad_vars`, read+write) and will
  reuse this transport unchanged. Building it once now avoids the
  retro-extraction EN-9 had to perform for the shared AWS identity seam. See
  `docs/adr/0022-nomad-jobs-adapter.md`.

  ## The destination is deployment configuration, never a caller's choice

  The base URL comes from `NOMAD_ADDR`, validated the same way
  `Nucleus.TenantApi.Http`'s `url/0` guards against SSRF (`PRX-A07`): a
  missing, blank, or unparseable base URL is `{:error, %Error{kind:
  :not_configured}}` **with no request attempted**, never a crash and never a
  request to some default host. `path` is supplied by the calling boundary
  (`/v1/jobs`, `/v1/job/:id`, ...), never by an end user.

  ## Auth is a static deployment token, not a passthrough

  `X-Nomad-Token` is set from `NOMAD_TOKEN` per
  `docs/requirements/ADR-0006-Nomad-API-Authentication.md`'s static-ACL-token
  decision. The header is omitted entirely when the token is unset or blank —
  never sent as an empty string.

  ## Failure is prompt and total

  `retry: false` — a retry ladder turns a clean fail-closed rejection into a
  hung caller, the same reasoning `Nucleus.TenantApi.Http` states for the
  tenant API. `redirect: false` — a redirect risks carrying the token to
  whatever host it names; it maps to `:unavailable` like any other unexpected
  status. `receive_timeout` bounds **one** request (10s by default, Decision 8
  — `docs/adr/0022-nomad-jobs-adapter.md`); the overall fan-out budget belongs
  to the caller (`Nucleus.NomadJobs.list/1`), not this transport.

  ## Never log the token, never log the body

  Only the status, a per-call request identifier, and — on transport failure —
  the error's reason. Matches `Nucleus.TenantApi.Http`'s logging discipline
  exactly.

  ## Assumed response shape

  A top-level JSON object or array, per Nomad's own HTTP API. This is
  asserted rather than guessed at: an undecodable or absent body on a `200` is
  `:unavailable`, not a best-effort parse. Shape-specific validation (is this
  actually a list of jobs?) is the calling boundary's job, not this
  transport's — `request/3` hands back whatever `Jason.decode/1` produces.
  """

  require Logger

  alias Nucleus.Backend.Error

  @default_connect_timeout_ms 5_000
  @default_receive_timeout_ms 10_000

  @doc """
  Performs one Nomad HTTP API request.

  ## Options

    * `:boundary` (required) — the calling boundary (`:nomad_jobs` today, a
      future `:nomad_vars`), attributed on every `Nucleus.Backend.Error` this
      call can return.
    * `:query` — a keyword list of query parameters, URL-encoded by `Req`.

  Status mapping is an explicit `case`, never a default-to-success: `200`
  decodes the body; `401`/`403` map to `:auth_expired`; every other status,
  and any transport-level failure, maps to `:unavailable`.
  """
  @spec request(method :: atom(), path :: String.t(), opts :: keyword()) ::
          {:ok, map() | list()} | {:error, Error.t()}
  def request(method, path, opts \\ [])
      when is_atom(method) and is_binary(path) and is_list(opts) do
    boundary = Keyword.fetch!(opts, :boundary)
    query = Keyword.get(opts, :query, [])
    request_id = request_id()

    with {:ok, url} <- url(path, boundary) do
      perform(method, url, path, query, boundary, request_id)
    end
  end

  defp perform(method, url, path, query, boundary, request_id) do
    request =
      Req.new(
        [
          method: method,
          url: url,
          params: query,
          headers: headers(),
          retry: false,
          redirect: false,
          decode_body: false,
          receive_timeout: timeout(:receive_timeout_ms, @default_receive_timeout_ms),
          connect_options: [timeout: timeout(:connect_timeout_ms, @default_connect_timeout_ms)]
        ] ++ Keyword.take(config(), [:plug])
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        log(:info, method, path, "200", request_id)
        decode(body, boundary, request_id)

      {:ok, %Req.Response{status: status}} when status in [401, 403] ->
        log(:warning, method, path, status, request_id)

        {:error,
         error(boundary, :auth_expired, "nomad rejected our credentials", %{
           status: status,
           request_id: request_id
         })}

      {:ok, %Req.Response{status: status}} ->
        log(:warning, method, path, status, request_id)

        {:error,
         error(boundary, :unavailable, "nomad answered #{status}", %{
           status: status,
           request_id: request_id
         })}

      {:error, exception} ->
        Logger.warning(
          "nomad #{method} #{path} failed: #{transport_reason(exception)} " <>
            "request_id=#{request_id}"
        )

        {:error,
         error(boundary, :unavailable, "nomad is unreachable", %{
           reason: transport_reason(exception),
           request_id: request_id
         })}
    end
  end

  defp decode(body, boundary, request_id) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _reason} ->
        # The decoder's message quotes the offending input, so it is
        # deliberately not carried into `details` — that would put the
        # response body in a log, the same rule Nucleus.TenantApi.Http states.
        {:error,
         error(boundary, :unavailable, "nomad returned a body that is not JSON", %{
           request_id: request_id
         })}
    end
  end

  defp decode(_body, boundary, request_id) do
    {:error, error(boundary, :unavailable, "nomad returned no body", %{request_id: request_id})}
  end

  defp url(path, boundary) do
    case config()[:base_url] do
      value when is_binary(value) -> validate_base_url(String.trim(value), path, boundary)
      _absent -> {:error, not_configured(boundary)}
    end
  end

  defp validate_base_url(base_url, path, boundary) do
    case URI.new(base_url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, String.trim_trailing(base_url, "/") <> path}

      _invalid ->
        {:error, not_configured(boundary)}
    end
  end

  defp not_configured(boundary) do
    error(
      boundary,
      :not_configured,
      "NOMAD_ADDR is missing or is not an http(s) URL",
      %{variable: "NOMAD_ADDR"}
    )
  end

  defp headers do
    case config()[:token] do
      token when is_binary(token) and token != "" ->
        [{"accept", "application/json"}, {"x-nomad-token", token}]

      _blank_or_nil ->
        [{"accept", "application/json"}]
    end
  end

  defp timeout(key, default) do
    case config()[key] do
      ms when is_integer(ms) and ms > 0 -> ms
      _absent_or_invalid -> default
    end
  end

  defp log(level, method, path, status, request_id) do
    Logger.log(level, "nomad #{method} #{path} -> #{status} request_id=#{request_id}")
  end

  defp transport_reason(%{reason: reason}), do: inspect(reason)
  defp transport_reason(%module{}), do: inspect(module)
  defp transport_reason(other), do: inspect(other)

  defp request_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp config, do: Application.get_env(:nucleus, __MODULE__, [])

  defp error(boundary, kind, message, details) do
    Error.new(kind, boundary, message, details)
  end
end
