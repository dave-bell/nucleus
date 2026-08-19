defmodule Nucleus.Aws.Client do
  @moduledoc """
  Builds an `%AWS.Client{}` wired to `Nucleus.Aws.ReqHttpClient`.

  Reads **no application env** — not the region, not the `:plug` test seam.
  Both arrive as arguments, because each adapter (`Nucleus.Secrets.Store.Aws`
  today, `Nucleus.M2M.Clients.Cognito` from EN-10) needs its own value for
  each: `aws_test.exs` and the future `cognito_test.exs` install different
  `Req.Test` stubs, and the two boundaries' regions may differ once
  `COGNITO_REGION` exists.
  """

  alias AWS.Client

  @doc """
  Builds a client from a set of AWS credentials, a region, and the
  HTTP-client options each adapter reads from its own config (currently just
  `:plug`, for the `Req.Test` seam).
  """
  @spec build_client(String.t(), String.t(), String.t() | nil, String.t(), keyword()) ::
          AWS.Client.t()
  def build_client(
        access_key_id,
        secret_access_key,
        session_token,
        region,
        http_client_opts \\ []
      ) do
    Client.create(access_key_id, secret_access_key, session_token, region)
    |> Client.put_http_client({Nucleus.Aws.ReqHttpClient, http_client_opts})
  end
end
