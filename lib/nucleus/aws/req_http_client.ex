defmodule Nucleus.Aws.ReqHttpClient do
  @moduledoc """
  `AWS.HTTPClient` behaviour, dispatching through `Req`.

  The `aws` package ships adapters for Hackney and Finch; neither is `Req`, and
  `AGENTS.md` mandates `Req` for every outbound HTTP call in this application.
  This is the one adapter that satisfies `AWS.HTTPClient` while keeping that
  true — attached to an `%AWS.Client{}` with `AWS.Client.put_http_client/2`:

      AWS.Client.create(access_key_id, secret_access_key, session_token, region)
      |> AWS.Client.put_http_client({Nucleus.Aws.ReqHttpClient, []})

  Boundary-agnostic on purpose: nothing here names SSM, STS, or the `:secrets`
  boundary. The future Cognito implementation (see EN-4's Out of scope) reuses
  this same module.

  ## Never logs

  This module logs nothing, in either branch. `PutParameter` sends a secret
  value in its request body, and any code path that logs a request body on
  failure is a secret leak — the simplest way to guarantee that never happens
  here is for this shared, boundary-agnostic adapter to never call `Logger` at
  all. A boundary that wants to log an operation does so above this layer,
  where it knows which fields are safe (see `Nucleus.Secrets.Store.Aws`).

  ## Retry shape

  Transport failures are re-shaped to match the Finch/Mint pattern
  `AWS.Client`'s built-in retry logic already recognises
  (`%{reason: :timeout}` / `%{reason: :closed}`), so `enable_retries?: true`
  continues to retry transport failures through this adapter exactly as it
  would through the bundled Finch adapter. `Req`'s own retry behaviour is
  disabled (`retry: false`) so there is exactly one retry policy in effect,
  not two racing each other.
  """

  @behaviour AWS.HTTPClient

  @impl AWS.HTTPClient
  def request(method, url, body, headers, options) do
    request =
      Req.new(
        method: method,
        url: url,
        headers: headers,
        body: body,
        retry: false
      )
      |> Req.merge(
        Keyword.take(options, [:receive_timeout, :connect_options, :pool_timeout, :plug])
      )

    case Req.request(request) do
      {:ok, %Req.Response{status: status, headers: resp_headers, body: resp_body}} ->
        {:ok, %{status_code: status, headers: headers_list(resp_headers), body: body(resp_body)}}

      {:error, %Req.TransportError{reason: reason}} when reason in [:timeout, :closed] ->
        {:error, %{reason: reason}}

      {:error, exception} ->
        {:error, exception}
    end
  end

  # Req normalises response headers into a map of value lists; AWS.Request
  # expects a list of {binary, binary} tuples (it calls `List.keyfind/3` on
  # this), so flatten it back out.
  defp headers_list(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {key, values} -> Enum.map(List.wrap(values), &{key, &1}) end)
  end

  defp body(body) when is_binary(body), do: body
  defp body(body), do: IO.iodata_to_binary(body)
end
