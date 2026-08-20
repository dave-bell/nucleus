defmodule Nucleus.M2M.Clients.Cognito do
  @moduledoc """
  Cognito App Clients configured for the `client_credentials` OAuth flow, in
  this tenant's own user pool, via an assumed role scoped to `cognito-idp`.

  Built on the [`aws`](https://hex.pm/packages/aws) package against an
  `%AWS.Client{}`, exactly like `Nucleus.Secrets.Store.Aws` — see
  `docs/adr/0007-secrets-store-adapter.md` for why `aws` over `ex_aws`. Unlike
  `Nucleus.Secrets.Store.Aws`, credential handling and AWS error
  classification are **shared** machinery, extracted by EN-9
  (`docs/adr/0015-shared-aws-identity-seam.md`): this module assembles the
  `spec`/`ctx` `Nucleus.Aws.Credentials` and `Nucleus.Aws.Error` need from its
  own config and holds no credential, client-construction, or generic
  error-classification code of its own.

  ## `COGNITO_ROLE_ARN`'s session is `nucleus-m2m`, deliberately

  Not cosmetic: it is part of `Nucleus.Aws.CredentialCache`'s key
  (`{role_arn, external_id, session_name}`) and it is what CloudTrail
  attributes these `cognito-idp` calls to. If `COGNITO_ROLE_ARN` and
  `TENANT_ROLE_ARN` are ever configured to the same role, the differing
  session names mean two cache slots and one extra `AssumeRole` per hour —
  traded deliberately for exact per-boundary CloudTrail attribution. See
  `docs/adr/0015-shared-aws-identity-seam.md`.

  ## Two facts about the Cognito API that drive this module's shape

  Verified directly against the pinned `aws` dependency
  (`deps/aws/lib/aws/generated/cognito_identity_provider.ex`):

    * `DescribeUserPoolClient` returns the client secret in plaintext
      (`"ClientSecret"`). It is dropped at this module's edge — `to_detail/1`
      never references that key, so there is no separate "strip the secret"
      step that could be skipped by accident.
    * `ListUserPoolClients` returns no creation date at all
      (`user_pool_client_description` is `ClientId`/`ClientName`/`UserPoolId`
      only), so `list_clients/0` fans out one `DescribeUserPoolClient` per
      client via `Task.async_stream/3`
      ([Decision 6](https://github.com/dave-bell/nucleus/issues/33#issuecomment-5349943455)).
      A describe failure degrades that one row rather than the whole list.

  ## No duplicate-name rejection

  Cognito does not require `ClientName` to be unique — verified against AWS's
  own `CreateUserPoolClient` API reference, whose error list contains nothing
  duplicate-name-shaped. `create_client/2` always creates the client it is
  asked to; see the
  [decision](https://github.com/dave-bell/nucleus/issues/33#issuecomment-5350191153)
  removing `M2M-A09`.

  ## Logging discipline — non-negotiable

  Every logged line names the operation, the client ID, and the request ID —
  never the request or response map, on any branch including failures.
  `CreateUserPoolClient`'s response and `AddUserPoolClientSecret`'s response
  both carry secret material, and `AddUserPoolClientSecret`'s *request* can
  too (the optional `ClientSecret` input this module never sends). Same rule
  `Nucleus.Secrets.Store.Aws` states about `PutParameter`.

  ## Configuration

  Read from `Application.get_env(:nucleus, __MODULE__, [])`, set by
  `config/runtime.exs`:

    * `:user_pool_id` (`COGNITO_USER_POOL_ID`) — no boot check; `nil` is
      `{:error, %Error{kind: :not_configured}}`, never a crash.
    * `:role_arn` (`COGNITO_ROLE_ARN`) — raises at boot when `:m2m` runs this
      implementation; `nil` in `:dev`/`:test` (which never run that check) is
      also `:not_configured`, never a crash.
    * `:region` (`COGNITO_REGION`) — same boot behaviour as `:role_arn`. No
      fallback to `AWS_REGION`.
    * `:external_id` (`COGNITO_STS_EXTERNAL_ID`) — optional.
    * `:plug` — the `Req.Test` seam, test-only.
  """

  @behaviour Nucleus.M2M.Clients

  require Logger

  alias Nucleus.Aws.Credentials
  alias Nucleus.Aws.Error, as: AwsError
  alias Nucleus.Backend.Error
  alias Nucleus.M2M.Client
  alias Nucleus.M2M.ClientCredentials
  alias Nucleus.M2M.ClientDetail
  alias Nucleus.M2M.Clients

  @session_name "nucleus-m2m"
  @max_concurrency 10
  @list_page_size 60

  @cognito_codes %{
    "ResourceNotFoundException" => :not_found,
    "ScopeDoesNotExistException" => :not_configured
  }

  @impl Clients
  def list_clients do
    with {:ok, client, pool_id} <- client_and_pool(),
         {:ok, descriptions} <- list_all(client, pool_id) do
      {:ok, describe_all(client, pool_id, descriptions)}
    end
  end

  @impl Clients
  def describe_client(client_id) do
    with {:ok, client, pool_id} <- client_and_pool() do
      describe(client, pool_id, client_id)
    end
  end

  @impl Clients
  def create_client(client_name, settings) do
    with {:ok, minutes} <- validate_token_validity(settings),
         {:ok, client, pool_id} <- client_and_pool() do
      do_create_client(client, pool_id, client_name, minutes)
    end
  end

  @impl Clients
  def rotate_secret(client_id) do
    with {:ok, client, pool_id} <- client_and_pool() do
      do_rotate_secret(client, pool_id, client_id)
    end
  end

  @impl Clients
  def health_check do
    with {:ok, client, pool_id} <- client_and_pool(),
         {:ok, _body} <- list_user_pool_clients(client, pool_id, 1, nil) do
      :ok
    end
  end

  # -- list_clients/0 -------------------------------------------------------

  defp list_all(client, pool_id), do: list_all(client, pool_id, nil, [])

  defp list_all(client, pool_id, next_token, acc) do
    with {:ok, body} <- list_user_pool_clients(client, pool_id, @list_page_size, next_token) do
      acc = acc ++ Map.get(body, "UserPoolClients", [])

      case body["NextToken"] do
        next_token when is_binary(next_token) and next_token != "" ->
          list_all(client, pool_id, next_token, acc)

        _no_more_pages ->
          {:ok, acc}
      end
    end
  end

  defp list_user_pool_clients(client, pool_id, max_results, next_token) do
    request_id = request_id()
    Logger.info("m2m aws list_user_pool_clients request_id=#{request_id}")

    input =
      %{"UserPoolId" => pool_id, "MaxResults" => max_results}
      |> maybe_put("NextToken", next_token)

    client
    |> AWS.CognitoIdentityProvider.list_user_pool_clients(input)
    |> then(&AwsError.unwrap(client, &1))
    |> AwsError.as_backend_result(cognito_ctx(), request_id)
  end

  defp describe_all(client, pool_id, descriptions) do
    descriptions
    |> Task.async_stream(&describe_for_list(client, pool_id, &1),
      max_concurrency: @max_concurrency,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, row} -> row end)
  end

  defp describe_for_list(client, pool_id, %{"ClientId" => client_id, "ClientName" => client_name}) do
    case describe(client, pool_id, client_id) do
      {:ok, %ClientDetail{created_date: created_date}} ->
        %Client{
          client_id: client_id,
          client_name: client_name,
          created_date: created_date,
          created_date_error: nil
        }

      {:error, %Error{kind: kind}} ->
        %Client{
          client_id: client_id,
          client_name: client_name,
          created_date: nil,
          created_date_error: kind
        }
    end
  end

  # -- describe_client/1, and list_clients/0's per-row describe ------------

  defp describe(client, pool_id, client_id) do
    request_id = request_id()

    Logger.info(
      "m2m aws describe_user_pool_client client_id=#{client_id} request_id=#{request_id}"
    )

    client
    |> AWS.CognitoIdentityProvider.describe_user_pool_client(%{
      "UserPoolId" => pool_id,
      "ClientId" => client_id
    })
    |> then(&AwsError.unwrap(client, &1))
    |> AwsError.as_backend_result(cognito_ctx(), request_id)
    |> case do
      {:ok, %{"UserPoolClient" => user_pool_client}} -> {:ok, to_detail(user_pool_client)}
      {:error, error} -> {:error, error}
    end
  end

  # Never references "ClientSecret" — the struct this builds has no field for
  # it, and this function has no reason to look at it either.
  defp to_detail(%{"ClientId" => client_id, "ClientName" => client_name} = user_pool_client) do
    %ClientDetail{
      client_id: client_id,
      client_name: client_name,
      scope: user_pool_client |> Map.get("AllowedOAuthScopes", []) |> Enum.join(" "),
      token_validity_seconds: token_validity_seconds(user_pool_client),
      created_date: epoch_to_datetime(user_pool_client["CreationDate"])
    }
  end

  # A client this feature created always has both set (see do_create_client/4).
  # A client created outside this feature (Terraform, the console) can omit
  # AccessTokenValidity entirely — that is the pool's own default, one hour.
  defp token_validity_seconds(%{"AccessTokenValidity" => value} = user_pool_client)
       when is_number(value) do
    unit = user_pool_client |> Map.get("TokenValidityUnits") |> access_token_unit()
    trunc(value) * seconds_per_unit(unit)
  end

  defp token_validity_seconds(_user_pool_client), do: 3600

  defp access_token_unit(%{"AccessToken" => unit}) when is_binary(unit), do: unit
  defp access_token_unit(_other), do: "hours"

  defp seconds_per_unit("seconds"), do: 1
  defp seconds_per_unit("minutes"), do: 60
  defp seconds_per_unit("hours"), do: 3600
  defp seconds_per_unit("days"), do: 86_400
  defp seconds_per_unit(_unrecognised), do: 3600

  # -- create_client/2 -------------------------------------------------------

  defp validate_token_validity(settings) do
    range = Clients.token_validity_range()
    minutes = Keyword.get(settings, :token_validity_minutes)

    if is_integer(minutes) and minutes in range do
      {:ok, minutes}
    else
      {:error,
       invalid_error(
         "token_validity_minutes must be a whole number of minutes from " <>
           "#{range.first} to #{range.last} inclusive, got: #{inspect(minutes)}"
       )}
    end
  end

  defp do_create_client(client, pool_id, client_name, minutes) do
    request_id = request_id()

    Logger.info(
      "m2m aws create_user_pool_client client_name=#{client_name} request_id=#{request_id}"
    )

    input = %{
      "UserPoolId" => pool_id,
      "ClientName" => client_name,
      "GenerateSecret" => true,
      "AllowedOAuthFlows" => ["client_credentials"],
      "AllowedOAuthFlowsUserPoolClient" => true,
      "AllowedOAuthScopes" => [scope()],
      "AccessTokenValidity" => minutes,
      "TokenValidityUnits" => %{"AccessToken" => "minutes"}
    }

    client
    |> AWS.CognitoIdentityProvider.create_user_pool_client(input)
    |> then(&AwsError.unwrap(client, &1))
    |> AwsError.as_backend_result(cognito_ctx(), request_id)
    |> case do
      {:ok,
       %{
         "UserPoolClient" => %{
           "ClientId" => client_id,
           "ClientName" => returned_name,
           "ClientSecret" => client_secret
         }
       }} ->
        {:ok,
         %ClientCredentials{
           client_id: client_id,
           client_name: returned_name,
           client_secret: client_secret
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp scope, do: "#{Nucleus.Scope.tenant_namespace()}/api"

  # -- rotate_secret/1 -------------------------------------------------------
  #
  # Delete-then-add, never the reverse: adding first hits Cognito's two-secret
  # cap and fails, and if the add fails after a delete, the client is left
  # with exactly the secret that was already current — degraded, not broken.

  defp do_rotate_secret(client, pool_id, client_id) do
    with {:ok, %ClientDetail{client_name: client_name}} <- describe(client, pool_id, client_id),
         {:ok, secrets} <- list_secrets(client, pool_id, client_id),
         :ok <- maybe_delete_oldest(client, pool_id, client_id, secrets) do
      do_add_secret(client, pool_id, client_id, client_name)
    end
  end

  defp list_secrets(client, pool_id, client_id) do
    request_id = request_id()

    Logger.info(
      "m2m aws list_user_pool_client_secrets client_id=#{client_id} request_id=#{request_id}"
    )

    client
    |> AWS.CognitoIdentityProvider.list_user_pool_client_secrets(%{
      "UserPoolId" => pool_id,
      "ClientId" => client_id
    })
    |> then(&AwsError.unwrap(client, &1))
    |> AwsError.as_backend_result(cognito_ctx(), request_id)
    |> case do
      {:ok, body} -> {:ok, Map.get(body, "ClientSecrets", [])}
      {:error, error} -> {:error, error}
    end
  end

  defp maybe_delete_oldest(client, pool_id, client_id, secrets) when length(secrets) >= 2 do
    oldest = Enum.min_by(secrets, & &1["ClientSecretCreateDate"])
    delete_secret(client, pool_id, client_id, oldest["ClientSecretId"])
  end

  defp maybe_delete_oldest(_client, _pool_id, _client_id, _secrets), do: :ok

  defp delete_secret(client, pool_id, client_id, client_secret_id) do
    request_id = request_id()

    Logger.info(
      "m2m aws delete_user_pool_client_secret client_id=#{client_id} request_id=#{request_id}"
    )

    client
    |> AWS.CognitoIdentityProvider.delete_user_pool_client_secret(%{
      "UserPoolId" => pool_id,
      "ClientId" => client_id,
      "ClientSecretId" => client_secret_id
    })
    |> then(&AwsError.unwrap(client, &1))
    |> AwsError.as_backend_result(cognito_ctx(), request_id)
    |> case do
      {:ok, _body} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  # Deliberately never sends the optional "ClientSecret" input — letting AWS
  # generate the value means the secret exists nowhere in this process before
  # AWS has already generated it, for no benefit.
  defp do_add_secret(client, pool_id, client_id, client_name) do
    request_id = request_id()

    Logger.info(
      "m2m aws add_user_pool_client_secret client_id=#{client_id} request_id=#{request_id}"
    )

    client
    |> AWS.CognitoIdentityProvider.add_user_pool_client_secret(%{
      "UserPoolId" => pool_id,
      "ClientId" => client_id
    })
    |> then(&AwsError.unwrap(client, &1))
    |> AwsError.as_backend_result(cognito_ctx(), request_id)
    |> case do
      {:ok, %{"ClientSecretDescriptor" => %{"ClientSecretValue" => secret_value}}} ->
        {:ok,
         %ClientCredentials{
           client_id: client_id,
           client_name: client_name,
           client_secret: secret_value
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  # -- STS / credentials ------------------------------------------------------

  defp client_and_pool do
    with {:ok, pool_id} <- required(pool_id(), "COGNITO_USER_POOL_ID"),
         {:ok, role_arn} <- required(role_arn(), "COGNITO_ROLE_ARN"),
         {:ok, region} <- required(region(), "COGNITO_REGION"),
         {:ok, %{client: client}} <- Credentials.fetch(spec(role_arn, region)) do
      {:ok, client, pool_id}
    end
  end

  defp spec(role_arn, region) do
    %{
      boundary: Clients.boundary(),
      role_arn: role_arn,
      region: region,
      external_id: external_id(),
      session_name: @session_name,
      http_client_opts: Keyword.take(config(), [:plug])
    }
  end

  defp cognito_ctx do
    %{
      boundary: Clients.boundary(),
      cache_key: Credentials.cache_key(spec(role_arn(), region())),
      codes: @cognito_codes,
      transport_message: "the Cognito user pool is unreachable"
    }
  end

  # -- Shape helpers ------------------------------------------------------

  defp epoch_to_datetime(nil), do: nil
  defp epoch_to_datetime(epoch) when is_integer(epoch), do: DateTime.from_unix!(epoch)
  defp epoch_to_datetime(epoch) when is_float(epoch), do: DateTime.from_unix!(trunc(epoch))
  defp epoch_to_datetime(_other), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp required(value, _var) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value, var), do: {:error, not_configured("#{var} is missing or blank")}

  defp not_configured(message), do: error(:not_configured, message)
  defp invalid_error(message), do: error(:invalid, message)
  defp error(kind, message), do: Error.new(kind, Clients.boundary(), message, %{})

  defp request_id, do: 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp pool_id, do: config()[:user_pool_id]
  defp role_arn, do: config()[:role_arn]
  defp region, do: config()[:region]
  defp external_id, do: config()[:external_id]
  defp config, do: Application.get_env(:nucleus, __MODULE__, [])
end
