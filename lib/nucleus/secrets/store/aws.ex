defmodule Nucleus.Secrets.Store.Aws do
  @moduledoc """
  Parameter Store, in the tenant's own AWS account, via a cross-account role.

  This is the highest-risk surface in the application — see
  `docs/adr/0002-backend-adapter-boundaries.md`. Built on the
  [`aws`](https://hex.pm/packages/aws) package against an `%AWS.Client{}`
  configured with `Nucleus.Aws.ReqHttpClient`, per EN-4's decision log: `aws`
  is code-generated from the AWS SDK Go v2 models and already covers every
  call this needs, without pulling in `ex_aws`'s own HTTP client stack.

  ## Credential handling

  Assuming `TENANT_ROLE_ARN` and classifying AWS errors into
  `Nucleus.Backend.Error` is shared machinery, not specific to Parameter
  Store — see `Nucleus.Aws.Credentials` and `Nucleus.Aws.Error`. This module
  assembles the `spec`/`ctx` those shared modules need from its own config
  and holds no credential, client-construction, or generic error-
  classification code of its own. `TENANT_ROLE_ARN`'s AssumeRole session is
  named `nucleus-secrets`, and credentials are cached under that name — see
  `Nucleus.Aws.CredentialCache` for how that interacts with any other
  boundary assuming a different role.

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

  alias Nucleus.Aws.Credentials
  alias Nucleus.Aws.Error, as: AwsError
  alias Nucleus.Backend.Error
  alias Nucleus.Secrets.Path
  alias Nucleus.Secrets.Secret
  alias Nucleus.Secrets.SecretLocation
  alias Nucleus.Secrets.SecretRef
  alias Nucleus.Secrets.Store

  @session_name "nucleus-secrets"

  @ssm_codes %{
    "ParameterNotFound" => :not_found,
    "ParameterAlreadyExists" => :already_exists
  }

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
    |> then(&AwsError.unwrap(client, &1))
    |> AwsError.as_backend_result(ssm_ctx(), request_id)
  end

  defp get_parameter(client, environment, key, with_decryption) do
    path = Path.build(environment, key)
    request_id = request_id()
    Logger.info("secrets aws get_parameter path=#{path} request_id=#{request_id}")

    result =
      AWS.SSM.get_parameter(client, %{"Name" => path, "WithDecryption" => with_decryption})

    case result
         |> then(&AwsError.unwrap(client, &1))
         |> AwsError.as_backend_result(ssm_ctx(), request_id) do
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

    AwsError.unwrap(client, result) |> AwsError.as_backend_result(ssm_ctx(), request_id)
  end

  defp ssm_ctx do
    %{
      boundary: Store.boundary(),
      cache_key: Credentials.cache_key(spec(role_arn(), region())),
      codes: @ssm_codes,
      transport_message: "the tenant's AWS account is unreachable"
    }
  end

  # -- STS / credentials ------------------------------------------------------

  defp client do
    with {:ok, client, _account_id} <- client_and_account(), do: {:ok, client}
  end

  defp client_and_account do
    with :ok <- ensure_path_configured(),
         {:ok, role_arn} <- required(role_arn(), "TENANT_ROLE_ARN"),
         {:ok, region} <- required(region(), "AWS_REGION"),
         {:ok, %{client: client, account_id: account_id}} <-
           Credentials.fetch(spec(role_arn, region)) do
      {:ok, client, account_id}
    end
  end

  defp spec(role_arn, region) do
    %{
      boundary: Store.boundary(),
      role_arn: role_arn,
      region: region,
      external_id: external_id(),
      session_name: @session_name,
      http_client_opts: Keyword.take(config(), [:plug])
    }
  end

  defp ensure_path_configured do
    if Path.configured?() do
      :ok
    else
      {:error, not_configured("CLUSTER_NAME and DEPLOYMENT_NAME must both be set")}
    end
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
