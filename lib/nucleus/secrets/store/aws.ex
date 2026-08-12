defmodule Nucleus.Secrets.Store.Aws do
  @moduledoc """
  Parameter Store, in the tenant's own AWS account, via a cross-account role.

  This is the highest-risk surface in the application — see
  `docs/adr/0002-backend-adapter-boundaries.md`. Built on the
  [`aws`](https://hex.pm/packages/aws) package against an `%AWS.Client{}`
  configured with `Nucleus.Aws.ReqHttpClient`, per EN-4's decision log: `aws`
  is code-generated from the AWS SDK Go v2 models and already covers every
  call this needs, without pulling in `ex_aws`'s own HTTP client stack.

  ## Nucleus's own AWS identity

  Assuming `TENANT_ROLE_ARN` requires *some* AWS identity to call
  `sts:AssumeRole` as. That identity is Nucleus's own deployment
  configuration — not tenant-specific, and not a new config surface this
  ticket invents. It is read from the same environment variables any AWS SDK
  reads (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`),
  however the deployment platform makes them available. A missing pair is
  `{:error, %Error{kind: :not_configured}}`, never a crash.

  ## Credential handling

  `AWS.STS.assume_role/2` into `TENANT_ROLE_ARN` (`AWS_STS_EXTERNAL_ID` if
  configured), then `AWS.STS.get_caller_identity/2` on the *assumed* client to
  learn the tenant's account ID for ARN construction. Both are cached
  together in `Nucleus.Secrets.Store.Aws.CredentialCache`, keyed on nothing —
  one tenant per deployment — until `expiration - skew` (five minutes).

  On a credential-expiry-shaped failure (`ExpiredToken`, `ExpiredTokenException`,
  `InvalidClientTokenId`, `RequestExpired`) the cache is invalidated and the
  call returns `{:error, %Error{kind: :auth_expired}}`. Invalidating is what
  makes `SEC-A18`'s "a fresh attempt after re-authentication succeeds
  normally" true — retrying with the same rejected credentials would not.

  ## Parameter operations

    * `list_secrets/1` — `GetParametersByPath` on `Path.prefix(environment)`,
      `Recursive: false`, `WithDecryption: false`, paginated to completion.
    * `list_environments/0` / `list_all_secrets/0` — **one shared private
      function**, `GetParametersByPath` on `Path.prefix(nil)`,
      `Recursive: true`, `WithDecryption: false`, paginated to completion,
      parsing each `Name` into `{bucket, key}`.
    * `get_secret/2` — `GetParameter`, `WithDecryption: true`.
      `ParameterNotFound` → `:not_found`.
    * `create_secret/3` — `PutParameter`, `Type: "SecureString"`,
      `Overwrite: false`. AWS's own `ParameterAlreadyExists` rejection makes
      `SEC-A12` race-safe; a read-then-write check here would not be.
    * `update_secret/3` — a `GetParameter` existence check
      (`WithDecryption: false` — this path needs no `kms:Decrypt`), **then**
      `PutParameter` with `Overwrite: true`. `SEC-A06` is an edit; it must not
      be able to create.
    * `locate_secret/2` — path from `Nucleus.Secrets.Path.build/2`, ARN as
      `arn:aws:ssm:{region}:{account_id}:parameter{path}` — no separator
      between `parameter` and the path, which already begins with `/`.

  ## Logging discipline — non-negotiable

  Every logged line names the operation and the parameter *path* only, never
  the full request map — `PutParameter`'s request body carries the secret
  value, so nothing here ever interpolates that map wholesale into a log
  line, in any branch, including failure branches.
  """

  @behaviour Nucleus.Secrets.Store

  require Logger

  alias AWS.Client
  alias Nucleus.Backend.Error
  alias Nucleus.Secrets.Path
  alias Nucleus.Secrets.Secret
  alias Nucleus.Secrets.SecretLocation
  alias Nucleus.Secrets.SecretRef
  alias Nucleus.Secrets.Store
  alias Nucleus.Secrets.Store.Aws.CredentialCache

  @session_name "nucleus-secrets"
  @skew_seconds 300

  @expired_credential_codes ~w(ExpiredToken ExpiredTokenException InvalidClientTokenId RequestExpired)
  @access_denied_codes ~w(AccessDenied AccessDeniedException)
  @throttling_codes ~w(ThrottlingException Throttling TooManyRequestsException)

  @impl Store
  def list_secrets(environment) do
    with {:ok, client} <- client(),
         {:ok, params} <- list_by_path(client, Path.prefix(environment), false) do
      {:ok, Enum.map(params, &param_to_ref/1)}
    end
  end

  @impl Store
  def get_secret(environment, key) do
    with {:ok, client} <- client(),
         {:ok, parameter} <- get_parameter(client, environment, key, true) do
      {:ok,
       %Secret{
         key: key,
         path: parameter["Name"],
         arn: parameter["ARN"],
         value: parameter["Value"],
         last_modified: epoch_to_datetime(parameter["LastModifiedDate"])
       }}
    end
  end

  @impl Store
  def create_secret(environment, key, value) do
    with {:ok, client, account_id} <- client_and_account(),
         {:ok, _body} <- put_parameter(client, environment, key, value, false) do
      {:ok, secret_ref(environment, key, account_id)}
    end
  end

  @impl Store
  def update_secret(environment, key, value) do
    with {:ok, client, account_id} <- client_and_account(),
         {:ok, _parameter} <- get_parameter(client, environment, key, false),
         {:ok, _body} <- put_parameter(client, environment, key, value, true) do
      {:ok, secret_ref(environment, key, account_id)}
    end
  end

  @impl Store
  def locate_secret(environment, key) do
    with {:ok, _client, account_id} <- client_and_account() do
      path = Path.build(environment, key)
      {:ok, %SecretLocation{path: path, arn: build_arn(account_id, path)}}
    end
  end

  @impl Store
  def list_environments do
    with {:ok, client} <- client(),
         {:ok, params} <- list_by_path(client, Path.prefix(nil), true) do
      {:ok, params |> Enum.map(&bucket_of/1) |> Enum.uniq() |> Enum.sort()}
    end
  end

  @impl Store
  def list_all_secrets do
    with {:ok, client} <- client(),
         {:ok, params} <- list_by_path(client, Path.prefix(nil), true) do
      {:ok, Enum.map(params, &%{environment: bucket_of(&1), secret: param_to_ref(&1)})}
    end
  end

  @impl Store
  def health_check do
    with {:ok, client} <- client(),
         {:ok, _body} <- get_parameters_by_path(client, Path.prefix(nil), false, nil) do
      :ok
    end
  end

  # -- Parameter Store calls -------------------------------------------------

  defp list_by_path(client, path, recursive), do: list_by_path(client, path, recursive, nil, [])

  defp list_by_path(client, path, recursive, next_token, acc) do
    with {:ok, body} <- get_parameters_by_path(client, path, recursive, next_token) do
      acc = acc ++ Map.get(body, "Parameters", [])

      case body["NextToken"] do
        next_token when is_binary(next_token) and next_token != "" ->
          list_by_path(client, path, recursive, next_token, acc)

        _no_more_pages ->
          {:ok, acc}
      end
    end
  end

  defp get_parameters_by_path(client, path, recursive, next_token) do
    request_id = request_id()

    Logger.info(
      "secrets aws get_parameters_by_path path=#{path} recursive=#{recursive} request_id=#{request_id}"
    )

    input =
      %{"Path" => path, "Recursive" => recursive, "WithDecryption" => false}
      |> maybe_put("NextToken", next_token)

    client
    |> AWS.SSM.get_parameters_by_path(input)
    |> then(&unwrap(client, &1))
    |> as_backend_result(request_id)
  end

  defp get_parameter(client, environment, key, with_decryption) do
    path = Path.build(environment, key)
    request_id = request_id()
    Logger.info("secrets aws get_parameter path=#{path} request_id=#{request_id}")

    result =
      AWS.SSM.get_parameter(client, %{"Name" => path, "WithDecryption" => with_decryption})

    case result |> then(&unwrap(client, &1)) |> as_backend_result(request_id) do
      {:ok, %{"Parameter" => parameter}} -> {:ok, parameter}
      {:error, error} -> {:error, error}
    end
  end

  defp put_parameter(client, environment, key, value, overwrite) do
    path = Path.build(environment, key)
    request_id = request_id()

    Logger.info(
      "secrets aws put_parameter path=#{path} overwrite=#{overwrite} request_id=#{request_id}"
    )

    result =
      AWS.SSM.put_parameter(client, %{
        "Name" => path,
        "Value" => value,
        "Type" => "SecureString",
        "Overwrite" => overwrite
      })

    unwrap(client, result) |> as_backend_result(request_id)
  end

  # -- STS / credentials ------------------------------------------------------

  defp client do
    with {:ok, client, _account_id} <- client_and_account(), do: {:ok, client}
  end

  defp client_and_account do
    with :ok <- ensure_path_configured(),
         {:ok, cached} <- credentials(),
         {:ok, region} <- required(region(), "AWS_REGION") do
      client =
        build_client(cached.access_key_id, cached.secret_access_key, cached.session_token, region)

      {:ok, client, cached.account_id}
    end
  end

  defp ensure_path_configured do
    if Path.configured?() do
      :ok
    else
      {:error, not_configured("CLUSTER_NAME and DEPLOYMENT_NAME must both be set")}
    end
  end

  defp credentials do
    case CredentialCache.get() do
      %{expires_at: expires_at} = cached ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          {:ok, cached}
        else
          refresh_credentials()
        end

      nil ->
        refresh_credentials()
    end
  end

  defp refresh_credentials do
    with {:ok, role_arn} <- required(role_arn(), "TENANT_ROLE_ARN"),
         {:ok, region} <- required(region(), "AWS_REGION"),
         {:ok, base_client} <- base_client(region),
         {:ok, assumed} <- do_assume_role(base_client, role_arn),
         {:ok, assume_result} <- unwrap_result(assumed, "AssumeRoleResponse", "AssumeRoleResult") do
      creds = assume_result["Credentials"]

      assumed_client =
        build_client(
          creds["AccessKeyId"],
          creds["SecretAccessKey"],
          creds["SessionToken"],
          region
        )

      with {:ok, identity} <- do_get_caller_identity(assumed_client),
           {:ok, identity_result} <-
             unwrap_result(identity, "GetCallerIdentityResponse", "GetCallerIdentityResult") do
        cached = %{
          access_key_id: creds["AccessKeyId"],
          secret_access_key: creds["SecretAccessKey"],
          session_token: creds["SessionToken"],
          account_id: identity_result["Account"],
          expires_at: expires_at(creds["Expiration"])
        }

        CredentialCache.put(cached)
        {:ok, cached}
      end
    end
  end

  # STS is a query/XML-protocol service and this library's generic XML
  # decoder does not unwrap the operation envelope the way the JSON-protocol
  # SSM responses are already flat — `AWS.STS.assume_role/3`'s response
  # actually decodes to `%{"AssumeRoleResponse" => %{"AssumeRoleResult" =>
  # %{"Credentials" => ...}}}`, not `%{"Credentials" => ...}` at the top
  # level, whatever the generated module's documentation-only typespec claims.
  # Verified directly against `AWS.XML.decode!/2`, not assumed from docs.
  defp unwrap_result(body, response_key, result_key) do
    case get_in(body, [response_key, result_key]) do
      %{} = result ->
        {:ok, result}

      _other ->
        {:error, error(:unavailable, "AWS returned an unexpected #{response_key} shape", %{})}
    end
  end

  defp do_assume_role(client, role_arn) do
    request_id = request_id()
    Logger.info("secrets aws assume_role request_id=#{request_id}")

    input =
      %{"RoleArn" => role_arn, "RoleSessionName" => @session_name}
      |> maybe_put("ExternalId", external_id())

    client
    |> AWS.STS.assume_role(input)
    |> then(&unwrap(client, &1))
    |> as_backend_result(request_id)
  end

  defp do_get_caller_identity(client) do
    request_id = request_id()
    Logger.info("secrets aws get_caller_identity request_id=#{request_id}")

    client
    |> AWS.STS.get_caller_identity(%{})
    |> then(&unwrap(client, &1))
    |> as_backend_result(request_id)
  end

  defp base_client(region) do
    case {System.get_env("AWS_ACCESS_KEY_ID"), System.get_env("AWS_SECRET_ACCESS_KEY")} do
      {access_key_id, secret_access_key}
      when is_binary(access_key_id) and access_key_id != "" and is_binary(secret_access_key) and
             secret_access_key != "" ->
        {:ok,
         build_client(
           access_key_id,
           secret_access_key,
           System.get_env("AWS_SESSION_TOKEN"),
           region
         )}

      _missing ->
        {:error, not_configured("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY must both be set")}
    end
  end

  defp build_client(access_key_id, secret_access_key, session_token, region) do
    Client.create(access_key_id, secret_access_key, session_token, region)
    |> Client.put_http_client({Nucleus.Aws.ReqHttpClient, Keyword.take(config(), [:plug])})
  end

  # -- Response / error handling ---------------------------------------------

  defp unwrap(_client, {:ok, body, _resp}), do: {:ok, body}

  defp unwrap(
         client,
         {:error, {:unexpected_response, %{status_code: status, headers: headers, body: body}}}
       ) do
    {:error, {:aws_error, status, error_code(client, body, headers)}}
  end

  defp unwrap(_client, {:error, reason}), do: {:error, {:transport_error, reason}}

  defp as_backend_result({:ok, body}, _request_id), do: {:ok, body}

  defp as_backend_result({:error, reason}, request_id) do
    {:error, to_backend_error(reason, request_id)}
  end

  defp to_backend_error({:aws_error, status, code}, request_id)
       when code in @expired_credential_codes do
    CredentialCache.clear()

    error(:auth_expired, "AWS credentials expired", %{
      code: code,
      status: status,
      request_id: request_id
    })
  end

  defp to_backend_error({:aws_error, status, code}, request_id)
       when code in @access_denied_codes do
    error(:auth_expired, "AWS denied access", %{
      code: code,
      status: status,
      request_id: request_id
    })
  end

  defp to_backend_error({:aws_error, _status, "ParameterNotFound"}, request_id) do
    error(:not_found, "no such parameter", %{request_id: request_id})
  end

  defp to_backend_error({:aws_error, _status, "ParameterAlreadyExists"}, request_id) do
    error(:already_exists, "parameter already exists", %{request_id: request_id})
  end

  defp to_backend_error({:aws_error, status, code}, request_id)
       when code in @throttling_codes or status == 429 or status >= 500 do
    error(:unavailable, "AWS answered #{status}", %{
      code: code,
      status: status,
      request_id: request_id
    })
  end

  defp to_backend_error({:aws_error, status, code}, request_id) do
    error(:unavailable, "AWS answered #{status}", %{
      code: code,
      status: status,
      request_id: request_id
    })
  end

  defp to_backend_error({:transport_error, reason}, request_id) do
    error(:unavailable, "the tenant's AWS account is unreachable", %{
      reason: transport_reason(reason),
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

  # -- Shape helpers ------------------------------------------------------

  defp param_to_ref(%{"Name" => name, "ARN" => arn} = param) do
    %SecretRef{
      key: name |> String.split("/") |> List.last(),
      path: name,
      arn: arn,
      last_modified: epoch_to_datetime(param["LastModifiedDate"])
    }
  end

  defp bucket_of(%{"Name" => name}) do
    prefix = Path.prefix(nil) <> "/"

    name
    |> String.replace_prefix(prefix, "")
    |> String.split("/")
    |> List.first()
  end

  defp secret_ref(environment, key, account_id) do
    path = Path.build(environment, key)

    %SecretRef{
      key: key,
      path: path,
      arn: build_arn(account_id, path),
      last_modified: DateTime.utc_now()
    }
  end

  defp build_arn(account_id, path), do: "arn:aws:ssm:#{region()}:#{account_id}:parameter" <> path

  defp epoch_to_datetime(nil), do: nil
  defp epoch_to_datetime(epoch) when is_integer(epoch), do: DateTime.from_unix!(epoch)
  defp epoch_to_datetime(epoch) when is_float(epoch), do: DateTime.from_unix!(trunc(epoch))
  defp epoch_to_datetime(_other), do: nil

  # STS is a query/XML-protocol service: the generic XML decoder (AWS.XML,
  # via xmerl) returns text nodes verbatim, so `Credentials.Expiration`
  # arrives as the ISO8601 string AWS actually puts in the XML
  # ("2026-08-01T12:00:00Z"), not an epoch integer — unlike SSM's JSON
  # responses, which encode timestamps as numbers. Do not reuse
  # `epoch_to_datetime/1` here.
  defp parse_sts_timestamp(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_sts_timestamp(_other), do: nil

  # A missing or unparseable `Expiration` is treated as already-expired rather
  # than crashing — the next call simply re-`assume_role`s.
  defp expires_at(iso8601) do
    case parse_sts_timestamp(iso8601) do
      nil -> DateTime.utc_now()
      datetime -> DateTime.add(datetime, -@skew_seconds, :second)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp required(value, _var) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value, var), do: {:error, not_configured("#{var} is missing or blank")}

  defp not_configured(message), do: error(:not_configured, message, %{})

  defp error(kind, message, details), do: Error.new(kind, Store.boundary(), message, details)

  defp request_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp role_arn, do: config()[:role_arn]
  defp region, do: config()[:region]
  defp external_id, do: config()[:external_id]
  defp config, do: Application.get_env(:nucleus, __MODULE__, [])
end
