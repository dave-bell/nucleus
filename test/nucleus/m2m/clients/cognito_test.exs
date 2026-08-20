defmodule Nucleus.M2M.Clients.CognitoTest do
  # Credentials are cached in :persistent_term (global to the node), and
  # configuration is application-global, so these cannot run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nucleus.Aws.CredentialCache
  alias Nucleus.Backend.Error
  alias Nucleus.M2M.Clients.Cognito

  @moduletag :capture_log

  @stub __MODULE__
  @role_arn "arn:aws:iam::123456789012:role/CognitoRole"
  @region "us-east-1"
  @pool_id "us-east-1_EXAMPLE"
  @cache_key {@role_arn, nil, "nucleus-m2m"}
  @secrets_cache_key {"arn:aws:iam::123456789012:role/TenantRole", nil, "nucleus-secrets"}

  setup do
    original_cognito = Application.get_env(:nucleus, Cognito)
    original_access_key = System.get_env("AWS_ACCESS_KEY_ID")
    original_secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    original_session_token = System.get_env("AWS_SESSION_TOKEN")

    System.put_env("AWS_ACCESS_KEY_ID", "AKIAOWNEXAMPLE")
    System.put_env("AWS_SECRET_ACCESS_KEY", "ownsecretexample")
    System.delete_env("AWS_SESSION_TOKEN")

    Application.put_env(:nucleus, Cognito,
      role_arn: @role_arn,
      region: @region,
      external_id: nil,
      user_pool_id: @pool_id,
      plug: {Req.Test, @stub}
    )

    CredentialCache.clear(@cache_key)
    CredentialCache.clear(@secrets_cache_key)

    on_exit(fn ->
      Application.put_env(:nucleus, Cognito, original_cognito)
      restore_env("AWS_ACCESS_KEY_ID", original_access_key)
      restore_env("AWS_SECRET_ACCESS_KEY", original_secret_key)
      restore_env("AWS_SESSION_TOKEN", original_session_token)
      CredentialCache.clear(@cache_key)
      CredentialCache.clear(@secrets_cache_key)
    end)

    :ok
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  # -- Stub plumbing ----------------------------------------------------

  defp stub_with(overrides) do
    handlers = Map.merge(default_sts_handlers(), overrides)

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
      action = action_of(conn, raw_body)

      case Map.fetch(handlers, action) do
        {:ok, handler} -> handler.(conn, raw_body)
        :error -> flunk("unstubbed AWS action: #{inspect(action)}")
      end
    end)
  end

  defp action_of(conn, raw_body) do
    case Plug.Conn.get_req_header(conn, "x-amz-target") do
      [target] -> target |> String.split(".") |> List.last()
      [] -> raw_body |> URI.decode_query() |> Map.get("Action")
    end
  end

  defp default_sts_handlers do
    %{
      "AssumeRole" => fn conn, _body -> respond_xml(conn, 200, assume_role_xml()) end,
      "GetCallerIdentity" => fn conn, _body ->
        respond_xml(conn, 200, get_caller_identity_xml())
      end
    }
  end

  defp respond_xml(conn, status, body) do
    conn |> Plug.Conn.put_resp_content_type("text/xml") |> Plug.Conn.resp(status, body)
  end

  defp respond_json(conn, status, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/x-amz-json-1.1")
    |> Plug.Conn.resp(status, Jason.encode!(data))
  end

  defp aws_error(conn, status, type, message \\ "boom") do
    conn
    |> Plug.Conn.put_resp_header("x-amzn-errortype", type)
    |> respond_json(status, %{"__type" => type, "message" => message})
  end

  defp assume_role_xml(opts \\ []) do
    expiration =
      Keyword.get_lazy(opts, :expiration, fn ->
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      end)

    access_key_id = Keyword.get(opts, :access_key_id, "ASIAASSUMEDEXAMPLE")

    """
    <AssumeRoleResponse>
      <AssumeRoleResult>
        <Credentials>
          <AccessKeyId>#{access_key_id}</AccessKeyId>
          <SecretAccessKey>assumedsecretexample</SecretAccessKey>
          <SessionToken>assumedsessiontokenexample</SessionToken>
          <Expiration>#{expiration}</Expiration>
        </Credentials>
        <AssumedRoleUser>
          <Arn>arn:aws:sts::123456789012:assumed-role/CognitoRole/nucleus-m2m</Arn>
          <AssumedRoleId>AROAEXAMPLE:nucleus-m2m</AssumedRoleId>
        </AssumedRoleUser>
      </AssumeRoleResult>
      <ResponseMetadata>
        <RequestId>req-assume-role</RequestId>
      </ResponseMetadata>
    </AssumeRoleResponse>
    """
  end

  defp get_caller_identity_xml do
    """
    <GetCallerIdentityResponse>
      <GetCallerIdentityResult>
        <Arn>arn:aws:sts::123456789012:assumed-role/CognitoRole/nucleus-m2m</Arn>
        <UserId>AROAEXAMPLE:nucleus-m2m</UserId>
        <Account>123456789012</Account>
      </GetCallerIdentityResult>
      <ResponseMetadata>
        <RequestId>req-get-caller-identity</RequestId>
      </ResponseMetadata>
    </GetCallerIdentityResponse>
    """
  end

  defp user_pool_client_description(client_id, client_name) do
    %{"ClientId" => client_id, "ClientName" => client_name, "UserPoolId" => @pool_id}
  end

  defp user_pool_client(overrides \\ %{}) do
    Map.merge(
      %{
        "ClientId" => "client123",
        "ClientName" => "acme-control-plane-OPS-1-test",
        "ClientSecret" => "super-secret-value",
        "CreationDate" => 1_700_000_000,
        "AllowedOAuthScopes" => ["acme/api"],
        "AccessTokenValidity" => 15,
        "TokenValidityUnits" => %{"AccessToken" => "minutes"}
      },
      overrides
    )
  end

  # -- list_clients/0 -------------------------------------------------------

  describe "list_clients/0" do
    test "follows NextToken and consumes both pages" do
      stub_with(%{
        "ListUserPoolClients" => fn conn, raw_body ->
          case Jason.decode!(raw_body) do
            %{"NextToken" => "page-2"} ->
              respond_json(conn, 200, %{
                "UserPoolClients" => [user_pool_client_description("id-two", "client-two")]
              })

            _first_page ->
              respond_json(conn, 200, %{
                "UserPoolClients" => [user_pool_client_description("id-one", "client-one")],
                "NextToken" => "page-2"
              })
          end
        end,
        "DescribeUserPoolClient" => fn conn, raw_body ->
          %{"ClientId" => client_id} = Jason.decode!(raw_body)

          respond_json(conn, 200, %{
            "UserPoolClient" => user_pool_client(%{"ClientId" => client_id})
          })
        end
      })

      assert {:ok, clients} = Cognito.list_clients()
      assert Enum.map(clients, & &1.client_id) |> Enum.sort() == ["id-one", "id-two"]
    end

    test "a per-client DescribeUserPoolClient failure degrades that row, not the whole list" do
      stub_with(%{
        "ListUserPoolClients" => fn conn, _body ->
          respond_json(conn, 200, %{
            "UserPoolClients" => [
              user_pool_client_description("good-id", "good-client"),
              user_pool_client_description("deleted-id", "deleted-client"),
              user_pool_client_description("throttled-id", "throttled-client")
            ]
          })
        end,
        "DescribeUserPoolClient" => fn conn, raw_body ->
          case Jason.decode!(raw_body) do
            %{"ClientId" => "good-id"} ->
              respond_json(conn, 200, %{
                "UserPoolClient" => user_pool_client(%{"ClientId" => "good-id"})
              })

            %{"ClientId" => "deleted-id"} ->
              aws_error(conn, 400, "ResourceNotFoundException")

            %{"ClientId" => "throttled-id"} ->
              aws_error(conn, 400, "ThrottlingException")
          end
        end
      })

      assert {:ok, clients} = Cognito.list_clients()
      by_id = Map.new(clients, &{&1.client_id, &1})

      assert %{created_date: %DateTime{}, created_date_error: nil} = by_id["good-id"]
      assert %{created_date: nil, created_date_error: :not_found} = by_id["deleted-id"]
      assert %{created_date: nil, created_date_error: :unavailable} = by_id["throttled-id"]
    end

    test "an unexpected DescribeUserPoolClient response shape degrades that row, not the whole list" do
      stub_with(%{
        "ListUserPoolClients" => fn conn, _body ->
          respond_json(conn, 200, %{
            "UserPoolClients" => [
              user_pool_client_description("good-id", "good-client"),
              user_pool_client_description("malformed-id", "malformed-client")
            ]
          })
        end,
        "DescribeUserPoolClient" => fn conn, raw_body ->
          case Jason.decode!(raw_body) do
            %{"ClientId" => "good-id"} ->
              respond_json(conn, 200, %{
                "UserPoolClient" => user_pool_client(%{"ClientId" => "good-id"})
              })

            %{"ClientId" => "malformed-id"} ->
              # A response missing "UserPoolClient" entirely — something no
              # documented Cognito behaviour produces, but the per-row
              # fan-out must survive it without taking the whole list down.
              respond_json(conn, 200, %{})
          end
        end
      })

      log =
        capture_log(fn ->
          assert {:ok, clients} = Cognito.list_clients()
          by_id = Map.new(clients, &{&1.client_id, &1})

          assert %{created_date: %DateTime{}, created_date_error: nil} = by_id["good-id"]
          assert %{created_date: nil, created_date_error: :unavailable} = by_id["malformed-id"]
        end)

      refute log =~ "ClientSecret"
      refute log =~ "super-secret-value"
    end

    test "a failing ListUserPoolClients call fails the whole list" do
      stub_with(%{
        "ListUserPoolClients" => fn conn, _body ->
          aws_error(conn, 500, "InternalErrorException")
        end
      })

      assert {:error, %Error{kind: :unavailable}} = Cognito.list_clients()
    end
  end

  # -- describe_client/1 -----------------------------------------------------

  describe "describe_client/1" do
    for {unit, raw, expected_seconds} <- [
          {"seconds", 450, 450},
          {"minutes", 15, 900},
          {"hours", 1, 3600},
          {"days", 1, 86_400}
        ] do
      test "normalises TokenValidityUnits #{unit} to seconds" do
        stub_with(%{
          "DescribeUserPoolClient" => fn conn, _body ->
            respond_json(conn, 200, %{
              "UserPoolClient" =>
                user_pool_client(%{
                  "AccessTokenValidity" => unquote(raw),
                  "TokenValidityUnits" => %{"AccessToken" => unquote(unit)}
                })
            })
          end
        })

        assert {:ok, detail} = Cognito.describe_client("client123")
        assert detail.token_validity_seconds == unquote(expected_seconds)
      end
    end

    test "60 minutes, 1 hour, and 3600 seconds all normalise to 3600" do
      for {raw, unit} <- [{60, "minutes"}, {1, "hours"}, {3600, "seconds"}] do
        stub_with(%{
          "DescribeUserPoolClient" => fn conn, _body ->
            respond_json(conn, 200, %{
              "UserPoolClient" =>
                user_pool_client(%{
                  "AccessTokenValidity" => raw,
                  "TokenValidityUnits" => %{"AccessToken" => unit}
                })
            })
          end
        })

        assert {:ok, detail} = Cognito.describe_client("client123")
        assert detail.token_validity_seconds == 3600
      end
    end

    test "a missing AccessTokenValidity falls back to the pool default (3600) without crashing" do
      stub_with(%{
        "DescribeUserPoolClient" => fn conn, _body ->
          user_pool_client =
            user_pool_client()
            |> Map.delete("AccessTokenValidity")
            |> Map.delete("TokenValidityUnits")

          respond_json(conn, 200, %{"UserPoolClient" => user_pool_client})
        end
      })

      assert {:ok, detail} = Cognito.describe_client("client123")
      assert detail.token_validity_seconds == 3600
    end

    test "never includes a :client_secret key" do
      stub_with(%{
        "DescribeUserPoolClient" => fn conn, _body ->
          respond_json(conn, 200, %{"UserPoolClient" => user_pool_client()})
        end
      })

      assert {:ok, detail} = Cognito.describe_client("client123")
      refute Map.has_key?(detail, :client_secret)
    end

    test "ResourceNotFoundException maps to :not_found" do
      stub_with(%{
        "DescribeUserPoolClient" => fn conn, _body ->
          aws_error(conn, 400, "ResourceNotFoundException")
        end
      })

      assert {:error, %Error{kind: :not_found}} = Cognito.describe_client("missing")
    end

    test "ScopeDoesNotExistException maps to :not_configured" do
      stub_with(%{
        "DescribeUserPoolClient" => fn conn, _body ->
          aws_error(conn, 400, "ScopeDoesNotExistException")
        end
      })

      assert {:error, %Error{kind: :not_configured}} = Cognito.describe_client("client123")
    end
  end

  # -- create_client/2 -------------------------------------------------------

  describe "create_client/2" do
    test "sends client_credentials, AllowedOAuthFlowsUserPoolClient: true, GenerateSecret: true, and the derived scope" do
      test_pid = self()

      stub_with(%{
        "CreateUserPoolClient" => fn conn, raw_body ->
          decoded = Jason.decode!(raw_body)
          send(test_pid, {:create_user_pool_client, decoded})
          respond_json(conn, 200, %{"UserPoolClient" => user_pool_client()})
        end
      })

      assert {:ok, credentials} = Cognito.create_client("acme-client", token_validity_minutes: 15)
      assert credentials.client_secret == "super-secret-value"

      assert_received {:create_user_pool_client,
                       %{
                         "AllowedOAuthFlows" => ["client_credentials"],
                         "AllowedOAuthFlowsUserPoolClient" => true,
                         "GenerateSecret" => true,
                         "AllowedOAuthScopes" => [scope]
                       }}

      assert scope == "#{Nucleus.Scope.tenant_namespace()}/api"
    end

    test "sends AccessTokenValidity and TokenValidityUnits: minutes from the operator's input" do
      test_pid = self()

      stub_with(%{
        "CreateUserPoolClient" => fn conn, raw_body ->
          send(test_pid, {:create_user_pool_client, Jason.decode!(raw_body)})
          respond_json(conn, 200, %{"UserPoolClient" => user_pool_client()})
        end
      })

      assert {:ok, _credentials} =
               Cognito.create_client("acme-client", token_validity_minutes: 42)

      assert_received {:create_user_pool_client,
                       %{
                         "AccessTokenValidity" => 42,
                         "TokenValidityUnits" => %{"AccessToken" => "minutes"}
                       }}
    end

    test "rejects token_validity_minutes of 4 or 61 as :invalid, with no HTTP call" do
      test_pid = self()

      stub_with(%{
        "CreateUserPoolClient" => fn _conn, _body -> send(test_pid, :unexpected_call) end
      })

      assert {:error, %Error{kind: :invalid}} =
               Cognito.create_client("acme-client", token_validity_minutes: 4)

      assert {:error, %Error{kind: :invalid}} =
               Cognito.create_client("acme-client", token_validity_minutes: 61)

      refute_received :unexpected_call
    end

    test "accepts the boundary values 5 and 60" do
      stub_with(%{
        "CreateUserPoolClient" => fn conn, _body ->
          respond_json(conn, 200, %{"UserPoolClient" => user_pool_client()})
        end
      })

      assert {:ok, _} = Cognito.create_client("acme-client", token_validity_minutes: 5)
      assert {:ok, _} = Cognito.create_client("acme-client", token_validity_minutes: 60)
    end

    test "a duplicate name is accepted, matching Cognito's real behaviour" do
      stub_with(%{
        "CreateUserPoolClient" => fn conn, _body ->
          respond_json(conn, 200, %{"UserPoolClient" => user_pool_client()})
        end
      })

      assert {:ok, _first} = Cognito.create_client("acme-client", token_validity_minutes: 15)
      assert {:ok, _second} = Cognito.create_client("acme-client", token_validity_minutes: 15)
    end

    test "ScopeDoesNotExistException maps to :not_configured" do
      stub_with(%{
        "CreateUserPoolClient" => fn conn, _body ->
          aws_error(conn, 400, "ScopeDoesNotExistException")
        end
      })

      assert {:error, %Error{kind: :not_configured}} =
               Cognito.create_client("acme-client", token_validity_minutes: 15)
    end

    test "missing COGNITO_USER_POOL_ID is :not_configured, with no HTTP call attempted" do
      Application.put_env(:nucleus, Cognito,
        role_arn: @role_arn,
        region: @region,
        user_pool_id: nil,
        plug: {Req.Test, @stub}
      )

      test_pid = self()

      stub_with(%{
        "AssumeRole" => fn _conn, _body -> send(test_pid, :assume_role_called) end
      })

      assert {:error, %Error{kind: :not_configured}} =
               Cognito.create_client("acme-client", token_validity_minutes: 15)

      refute_received :assume_role_called
    end
  end

  # -- rotate_secret/1 -------------------------------------------------------

  describe "rotate_secret/1" do
    test "with one existing secret, issues no delete" do
      test_pid = self()

      stub_with(%{
        "DescribeUserPoolClient" => fn conn, _body ->
          respond_json(conn, 200, %{"UserPoolClient" => user_pool_client()})
        end,
        "ListUserPoolClientSecrets" => fn conn, _body ->
          respond_json(conn, 200, %{
            "ClientSecrets" => [
              %{"ClientSecretId" => "secret-1", "ClientSecretCreateDate" => 1_700_000_000}
            ]
          })
        end,
        "DeleteUserPoolClientSecret" => fn _conn, _body -> send(test_pid, :delete_called) end,
        "AddUserPoolClientSecret" => fn conn, _body ->
          respond_json(conn, 200, %{
            "ClientSecretDescriptor" => %{
              "ClientSecretId" => "secret-2",
              "ClientSecretCreateDate" => 1_700_000_100,
              "ClientSecretValue" => "new-secret-value"
            }
          })
        end
      })

      assert {:ok, credentials} = Cognito.rotate_secret("client123")
      assert credentials.client_id == "client123"
      assert credentials.client_secret == "new-secret-value"
      refute_received :delete_called
    end

    test "with two existing secrets, deletes the one with the older ClientSecretCreateDate" do
      test_pid = self()

      stub_with(%{
        "DescribeUserPoolClient" => fn conn, _body ->
          respond_json(conn, 200, %{"UserPoolClient" => user_pool_client()})
        end,
        "ListUserPoolClientSecrets" => fn conn, _body ->
          respond_json(conn, 200, %{
            "ClientSecrets" => [
              %{"ClientSecretId" => "newer", "ClientSecretCreateDate" => 1_700_000_200},
              %{"ClientSecretId" => "older", "ClientSecretCreateDate" => 1_700_000_000}
            ]
          })
        end,
        "DeleteUserPoolClientSecret" => fn conn, raw_body ->
          send(test_pid, {:delete_called, Jason.decode!(raw_body)})
          respond_json(conn, 200, %{})
        end,
        "AddUserPoolClientSecret" => fn conn, _body ->
          respond_json(conn, 200, %{
            "ClientSecretDescriptor" => %{
              "ClientSecretId" => "secret-3",
              "ClientSecretCreateDate" => 1_700_000_300,
              "ClientSecretValue" => "newest-secret-value"
            }
          })
        end
      })

      assert {:ok, _credentials} = Cognito.rotate_secret("client123")
      assert_received {:delete_called, %{"ClientSecretId" => "older"}}
    end

    test "on an unknown client, ResourceNotFoundException maps to :not_found" do
      stub_with(%{
        "DescribeUserPoolClient" => fn conn, _body ->
          aws_error(conn, 400, "ResourceNotFoundException")
        end
      })

      assert {:error, %Error{kind: :not_found}} = Cognito.rotate_secret("missing")
    end
  end

  # -- health_check/0 --------------------------------------------------------

  describe "health_check/0" do
    test "is :ok when Cognito answers" do
      stub_with(%{
        "ListUserPoolClients" => fn conn, _body ->
          respond_json(conn, 200, %{"UserPoolClients" => []})
        end
      })

      assert Cognito.health_check() == :ok
    end

    test "is :unavailable on a transport error" do
      stub_with(%{
        "ListUserPoolClients" => fn conn, _body -> Req.Test.transport_error(conn, :timeout) end
      })

      assert {:error, %Error{kind: :unavailable}} = Cognito.health_check()
    end
  end

  # -- Error mapping shared across operations ------------------------------

  describe "error mapping" do
    for code <- ~w(ExpiredToken ExpiredTokenException InvalidClientTokenId RequestExpired) do
      test "#{code} on DescribeUserPoolClient maps to :auth_expired and clears only this boundary's cache slot" do
        CredentialCache.put(@secrets_cache_key, %{sentinel: :untouched})

        stub_with(%{
          "DescribeUserPoolClient" => fn conn, _body -> aws_error(conn, 400, unquote(code)) end
        })

        assert {:error, %Error{kind: :auth_expired}} = Cognito.describe_client("client123")
        assert CredentialCache.get(@cache_key) == nil
        assert CredentialCache.get(@secrets_cache_key) == %{sentinel: :untouched}
      end
    end

    test "throttling maps to :unavailable" do
      stub_with(%{
        "DescribeUserPoolClient" => fn conn, _body ->
          aws_error(conn, 400, "ThrottlingException")
        end
      })

      assert {:error, %Error{kind: :unavailable}} = Cognito.describe_client("client123")
    end

    test "a 500 maps to :unavailable" do
      stub_with(%{
        "DescribeUserPoolClient" => fn conn, _body ->
          aws_error(conn, 500, "InternalErrorException")
        end
      })

      assert {:error, %Error{kind: :unavailable}} = Cognito.describe_client("client123")
    end

    test "a transport error maps to :unavailable" do
      stub_with(%{
        "DescribeUserPoolClient" => fn conn, _body ->
          Req.Test.transport_error(conn, :econnrefused)
        end
      })

      assert {:error, %Error{kind: :unavailable}} = Cognito.describe_client("client123")
    end

    test "an unset COGNITO_ROLE_ARN is :not_configured, with no request attempted" do
      Application.put_env(:nucleus, Cognito,
        role_arn: nil,
        region: @region,
        user_pool_id: @pool_id,
        plug: {Req.Test, @stub}
      )

      test_pid = self()

      stub_with(%{
        "AssumeRole" => fn _conn, _body -> send(test_pid, :assume_role_called) end
      })

      assert {:error, %Error{kind: :not_configured}} = Cognito.describe_client("client123")
      refute_received :assume_role_called
    end

    test "unset AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY is :not_configured" do
      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")

      assert {:error, %Error{kind: :not_configured}} = Cognito.describe_client("client123")
    end
  end

  # -- Credential caching --------------------------------------------------

  describe "credential caching" do
    test "AssumeRole is called once across two operations, within the credential lifetime" do
      test_pid = self()

      stub_with(%{
        "AssumeRole" => fn conn, _body ->
          send(test_pid, :assume_role_called)
          respond_xml(conn, 200, assume_role_xml())
        end,
        "DescribeUserPoolClient" => fn conn, _body ->
          respond_json(conn, 200, %{"UserPoolClient" => user_pool_client()})
        end
      })

      assert {:ok, _} = Cognito.describe_client("client123")
      assert {:ok, _} = Cognito.describe_client("client123")

      assert_received :assume_role_called
      refute_received :assume_role_called
    end
  end

  # -- Logging discipline ---------------------------------------------------

  describe "logging discipline" do
    test "a successful create_client/2 never logs the secret" do
      stub_with(%{
        "CreateUserPoolClient" => fn conn, _body ->
          respond_json(conn, 200, %{
            "UserPoolClient" => user_pool_client(%{"ClientSecret" => "leak-me-please"})
          })
        end
      })

      log =
        capture_log(fn ->
          assert {:ok, credentials} =
                   Cognito.create_client("acme-client", token_validity_minutes: 15)

          assert credentials.client_secret == "leak-me-please"
        end)

      refute log =~ "leak-me-please"
    end

    test "a failed create_client/2 never logs the secret" do
      stub_with(%{
        "CreateUserPoolClient" => fn conn, _body ->
          aws_error(conn, 500, "InternalErrorException")
        end
      })

      log =
        capture_log(fn ->
          assert {:error, %Error{kind: :unavailable}} =
                   Cognito.create_client("acme-client", token_validity_minutes: 15)
        end)

      refute log =~ "InternalErrorException" && log =~ "ClientSecret"
    end

    test "a successful rotate_secret/1 never logs the secret" do
      stub_with(%{
        "DescribeUserPoolClient" => fn conn, _body ->
          respond_json(conn, 200, %{"UserPoolClient" => user_pool_client()})
        end,
        "ListUserPoolClientSecrets" => fn conn, _body ->
          respond_json(conn, 200, %{"ClientSecrets" => []})
        end,
        "AddUserPoolClientSecret" => fn conn, _body ->
          respond_json(conn, 200, %{
            "ClientSecretDescriptor" => %{
              "ClientSecretId" => "secret-x",
              "ClientSecretCreateDate" => 1_700_000_000,
              "ClientSecretValue" => "rotate-leak-me-please"
            }
          })
        end
      })

      log =
        capture_log(fn ->
          assert {:ok, credentials} = Cognito.rotate_secret("client123")
          assert credentials.client_secret == "rotate-leak-me-please"
        end)

      refute log =~ "rotate-leak-me-please"
    end
  end
end
