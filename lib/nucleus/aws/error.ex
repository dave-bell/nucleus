defmodule Nucleus.Aws.Error do
  @moduledoc """
  Turns an `AWS.Client` call result into a `Nucleus.Backend.Error`.

  Boundary-neutral: it reads no application env and knows nothing about
  SSM or Cognito specifically. Each adapter (`Nucleus.Secrets.Store.Aws`
  today, `Nucleus.M2M.Clients.Cognito` from EN-10) supplies a `ctx` per
  call, carrying the one `boundary` atom that ends up on the returned
  `Nucleus.Backend.Error` (callers distinguish two boundaries' `:unavailable`
  errors by `error.boundary`, per `Nucleus.Secrets`' moduledoc), the
  credential-cache key to invalidate on an expired-credential-shaped error,
  the adapter's own AWS error codes (SSM's `ParameterNotFound` and
  `ParameterAlreadyExists` are not meaningful to Cognito, and vice versa),
  and the boundary-specific transport-error message.

  ## Classification order

  Order matters and is deliberate — getting it wrong is how `SEC-A18` would
  silently stop invalidating the credential cache:

    1. Expired-credential-shaped codes (`ExpiredToken`, `ExpiredTokenException`,
       `InvalidClientTokenId`, `RequestExpired`) — clears the cache slot named
       by `ctx.cache_key` and returns `:auth_expired`.
    2. Access-denied codes (`AccessDenied`, `AccessDeniedException`) —
       `:auth_expired` (preserved as-is; this is existing behaviour, not a
       new classification).
    3. `ctx.codes` — the adapter's own code map, consulted *before* the
       generic rules so an adapter-specific code cannot be shadowed by them,
       and so an adapter code cannot shadow rule 1 (a code cannot appear in
       both an adapter's `codes` map and the expired-credential list without
       this ordering mattering).
    4. Throttling codes, HTTP 429, or HTTP 5xx — `:unavailable`.
    5. Everything else AWS answered with a status/code — `:unavailable`.
    6. A transport-level failure (no AWS response at all) — `:unavailable`,
       with `ctx.transport_message`.
  """

  alias Nucleus.Aws.CredentialCache
  alias Nucleus.Backend.Error

  @type ctx :: %{
          boundary: atom(),
          cache_key: term(),
          codes: %{String.t() => Error.kind()},
          transport_message: String.t()
        }

  @expired_credential_codes ~w(ExpiredToken ExpiredTokenException InvalidClientTokenId RequestExpired)
  @access_denied_codes ~w(AccessDenied AccessDeniedException)
  @throttling_codes ~w(ThrottlingException Throttling TooManyRequestsException)

  @doc """
  Normalises an `AWS.Client` call result into `{:ok, body} | {:error, reason}`,
  where `reason` is either `{:aws_error, status, code}` (AWS answered, but
  with an error) or `{:transport_error, reason}` (AWS was never reached).
  """
  @spec unwrap(AWS.Client.t(), term()) :: {:ok, map()} | {:error, term()}
  def unwrap(_client, {:ok, body, _resp}), do: {:ok, body}

  def unwrap(
        client,
        {:error, {:unexpected_response, %{status_code: status, headers: headers, body: body}}}
      ) do
    {:error, {:aws_error, status, error_code(client, body, headers)}}
  end

  def unwrap(_client, {:error, reason}), do: {:error, {:transport_error, reason}}

  @doc """
  Passes an `{:ok, _}` through unchanged, and classifies an `{:error, reason}`
  from `unwrap/2` into `{:error, %Nucleus.Backend.Error{}}` via `classify/3`.
  """
  @spec as_backend_result({:ok, term()} | {:error, term()}, ctx(), String.t()) ::
          {:ok, term()} | {:error, Error.t()}
  def as_backend_result({:ok, body}, _ctx, _request_id), do: {:ok, body}

  def as_backend_result({:error, reason}, ctx, request_id) do
    {:error, classify(reason, ctx, request_id)}
  end

  @doc """
  Classifies a `reason` from `unwrap/2` into a `Nucleus.Backend.Error`, per
  the order documented above.
  """
  @spec classify(term(), ctx(), String.t()) :: Error.t()
  def classify({:aws_error, status, code}, ctx, request_id)
      when code in @expired_credential_codes do
    CredentialCache.clear(ctx.cache_key)

    error(:auth_expired, ctx.boundary, "AWS credentials expired", %{
      code: code,
      status: status,
      request_id: request_id
    })
  end

  def classify({:aws_error, status, code}, ctx, request_id)
      when code in @access_denied_codes do
    error(:auth_expired, ctx.boundary, "AWS denied access", %{
      code: code,
      status: status,
      request_id: request_id
    })
  end

  def classify({:aws_error, status, code}, ctx, request_id) do
    case Map.fetch(ctx.codes, code) do
      {:ok, kind} ->
        error(kind, ctx.boundary, "AWS answered with #{code}", %{
          code: code,
          status: status,
          request_id: request_id
        })

      :error ->
        classify_by_status({:aws_error, status, code}, ctx, request_id)
    end
  end

  def classify({:transport_error, reason}, ctx, request_id) do
    error(:unavailable, ctx.boundary, ctx.transport_message, %{
      reason: transport_reason(reason),
      request_id: request_id
    })
  end

  defp classify_by_status({:aws_error, status, code}, ctx, request_id)
       when code in @throttling_codes or status == 429 or status >= 500 do
    error(:unavailable, ctx.boundary, "AWS answered #{status}", %{
      code: code,
      status: status,
      request_id: request_id
    })
  end

  defp classify_by_status({:aws_error, status, code}, ctx, request_id) do
    error(:unavailable, ctx.boundary, "AWS answered #{status}", %{
      code: code,
      status: status,
      request_id: request_id
    })
  end

  defp transport_reason(%{reason: reason}), do: inspect(reason)
  defp transport_reason(%module{}), do: inspect(module)
  defp transport_reason(other), do: inspect(other)

  defp error_code(client, body, headers) do
    case header_value(headers, "x-amzn-errortype") do
      nil -> body |> decode_error_body(client, headers) |> extract_code()
      value -> code_tail(value)
    end
  end

  defp decode_error_body(body, _client, _headers) when body in [nil, ""], do: %{}

  defp decode_error_body(body, client, headers) do
    content_type = header_value(headers, "content-type") || ""
    protocol = if String.contains?(content_type, "json"), do: :json, else: :xml

    try do
      AWS.Client.decode!(client, body, protocol)
    rescue
      _error -> %{}
    end
  end

  defp extract_code(decoded) do
    (decoded["__type"] || get_in(decoded, ["Error", "Code"])) |> code_tail()
  end

  defp code_tail(nil), do: nil
  defp code_tail(code) when is_binary(code), do: code |> String.split("#") |> List.last()

  defp header_value(headers, name) do
    Enum.find_value(headers, fn {key, value} -> if String.downcase(key) == name, do: value end)
  end

  defp error(kind, boundary, message, details), do: Error.new(kind, boundary, message, details)
end
