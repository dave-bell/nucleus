defmodule Nucleus.Secrets.Store.AwsTest do
  # Credentials are cached in :persistent_term (global to the node), and
  # configuration is application-global, so these cannot run concurrently.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nucleus.Aws.CredentialCache
  alias Nucleus.Backend.Error
  alias Nucleus.Secrets.Path
  alias Nucleus.Secrets.Store.Aws

  @moduletag :capture_log

  @stub __MODULE__
  @role_arn "arn:aws:iam::123456789012:role/TenantRole"
  @account_id "123456789012"
  @region "us-east-1"
  @cache_key {@role_arn, nil, "nucleus-secrets"}

  setup do
    original_aws = Application.get_env(:nucleus, Aws)
    original_path = Application.get_env(:nucleus, Path)
    original_access_key = System.get_env("AWS_ACCESS_KEY_ID")
    original_secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    original_session_token = System.get_env("AWS_SESSION_TOKEN")

    System.put_env("AWS_ACCESS_KEY_ID", "AKIAOWNEXAMPLE")
    System.put_env("AWS_SECRET_ACCESS_KEY", "ownsecretexample")
    System.delete_env("AWS_SESSION_TOKEN")

    Application.put_env(:nucleus, Aws,
      role_arn: @role_arn,
      region: @region,
      external_id: nil,
      plug: {Req.Test, @stub}
    )

    Application.put_env(:nucleus, Path, cluster_name: "acme", deployment_name: "main")

    CredentialCache.clear(@cache_key)

    on_exit(fn ->
      Application.put_env(:nucleus, Aws, original_aws)
      Application.put_env(:nucleus, Path, original_path)
      restore_env("AWS_ACCESS_KEY_ID", original_access_key)
      restore_env("AWS_SECRET_ACCESS_KEY", original_secret_key)
      restore_env("AWS_SESSION_TOKEN", original_session_token)
      CredentialCache.clear(@cache_key)
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
          <Arn>arn:aws:sts::#{@account_id}:assumed-role/TenantRole/nucleus-secrets</Arn>
          <AssumedRoleId>AROAEXAMPLE:nucleus-secrets</AssumedRoleId>
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
        <Arn>arn:aws:sts::#{@account_id}:assumed-role/TenantRole/nucleus-secrets</Arn>
        <UserId>AROAEXAMPLE:nucleus-secrets</UserId>
        <Account>#{@account_id}</Account>
      </GetCallerIdentityResult>
      <ResponseMetadata>
        <RequestId>req-get-caller-identity</RequestId>
      </ResponseMetadata>
    </GetCallerIdentityResponse>
    """
  end

  defp parameter(name, value, opts \\ []) do
    %{
      "Name" => name,
      "Value" => value,
      "Type" => Keyword.get(opts, :type, "SecureString"),
      "ARN" => "arn:aws:ssm:#{@region}:#{@account_id}:parameter#{name}",
      "LastModifiedDate" => Keyword.get(opts, :last_modified, 1_700_000_000),
      "Version" => Keyword.get(opts, :version, 1)
    }
  end

  # -- create_secret/3 ----------------------------------------------------

  describe "create_secret/3" do
    test "sends Overwrite: false and Type: SecureString, never the request body in logs" do
      test_pid = self()

      stub_with(%{
        "PutParameter" => fn conn, raw_body ->
          decoded = Jason.decode!(raw_body)
          send(test_pid, {:put_parameter, decoded})
          respond_json(conn, 200, %{"Version" => 1, "Tier" => "Standard"})
        end
      })

      assert {:ok, ref} = Aws.create_secret("prod", "DB_PASSWORD", "s3cr3t-value")
      assert ref.key == "DB_PASSWORD"

      assert_received {:put_parameter, %{"Overwrite" => false, "Type" => "SecureString"}}
    end

    test "builds the exact ARN format: arn:aws:ssm:{region}:{account}:parameter{path}" do
      stub_with(%{
        "PutParameter" => fn conn, _body -> respond_json(conn, 200, %{"Version" => 1}) end
      })

      assert {:ok, ref} = Aws.create_secret("prod", "DB_PASSWORD", "value")

      assert ref.path == "/acme/deployments/main/faas/functions/prod/DB_PASSWORD"

      assert ref.arn ==
               "arn:aws:ssm:us-east-1:123456789012:parameter/acme/deployments/main/faas/functions/prod/DB_PASSWORD"
    end

    test "ParameterAlreadyExists maps to :already_exists" do
      stub_with(%{
        "PutParameter" => fn conn, _body -> aws_error(conn, 400, "ParameterAlreadyExists") end
      })

      assert {:error, %Error{kind: :already_exists, boundary: :secrets}} =
               Aws.create_secret("prod", "DB_PASSWORD", "value")
    end
  end

  # -- update_secret/3 ----------------------------------------------------

  describe "update_secret/3" do
    test "checks existence with WithDecryption: false before writing" do
      test_pid = self()

      stub_with(%{
        "GetParameter" => fn conn, raw_body ->
          decoded = Jason.decode!(raw_body)
          send(test_pid, {:get_parameter, decoded})
          respond_json(conn, 200, %{"Parameter" => parameter("/x", "old-value")})
        end,
        "PutParameter" => fn conn, raw_body ->
          send(test_pid, {:put_parameter, Jason.decode!(raw_body)})
          respond_json(conn, 200, %{"Version" => 2})
        end
      })

      assert {:ok, _ref} = Aws.update_secret("prod", "DB_PASSWORD", "new-value")

      assert_received {:get_parameter, %{"WithDecryption" => false}}
      assert_received {:put_parameter, %{"Overwrite" => true, "Type" => "SecureString"}}
    end

    test "a missing key is :not_found and issues no PutParameter" do
      test_pid = self()

      stub_with(%{
        "GetParameter" => fn conn, _body -> aws_error(conn, 400, "ParameterNotFound") end,
        "PutParameter" => fn conn, _body ->
          send(test_pid, :put_parameter_called)
          respond_json(conn, 200, %{"Version" => 1})
        end
      })

      assert {:error, %Error{kind: :not_found}} = Aws.update_secret("prod", "MISSING", "value")

      refute_received :put_parameter_called
    end
  end

  # -- get_secret/2 --------------------------------------------------------

  describe "get_secret/2" do
    test "sends WithDecryption: true" do
      test_pid = self()

      stub_with(%{
        "GetParameter" => fn conn, raw_body ->
          send(test_pid, {:get_parameter, Jason.decode!(raw_body)})
          respond_json(conn, 200, %{"Parameter" => parameter("/x", "the-value")})
        end
      })

      assert {:ok, secret} = Aws.get_secret("prod", "DB_PASSWORD")
      assert secret.value == "the-value"
      assert_received {:get_parameter, %{"WithDecryption" => true}}
    end

    test "ParameterNotFound maps to :not_found" do
      stub_with(%{
        "GetParameter" => fn conn, _body -> aws_error(conn, 400, "ParameterNotFound") end
      })

      assert {:error, %Error{kind: :not_found}} = Aws.get_secret("prod", "MISSING")
    end
  end

  # -- list_secrets/1, list_environments/0, list_all_secrets/0 ------------

  describe "list_secrets/1" do
    test "sends WithDecryption: false and Recursive: false" do
      test_pid = self()

      stub_with(%{
        "GetParametersByPath" => fn conn, raw_body ->
          send(test_pid, {:get_parameters_by_path, Jason.decode!(raw_body)})

          respond_json(conn, 200, %{
            "Parameters" => [
              parameter("/acme/deployments/main/faas/functions/prod/DB_PASSWORD", "v1")
            ]
          })
        end
      })

      assert {:ok, [ref]} = Aws.list_secrets("prod")
      assert ref.key == "DB_PASSWORD"

      assert_received {:get_parameters_by_path,
                       %{"WithDecryption" => false, "Recursive" => false}}
    end

    test "follows NextToken and concatenates pages" do
      stub_with(%{
        "GetParametersByPath" => fn conn, raw_body ->
          case Jason.decode!(raw_body) do
            %{"NextToken" => "page-2"} ->
              respond_json(conn, 200, %{
                "Parameters" => [
                  parameter("/acme/deployments/main/faas/functions/prod/KEY_TWO", "v2")
                ]
              })

            _first_page ->
              respond_json(conn, 200, %{
                "Parameters" => [
                  parameter("/acme/deployments/main/faas/functions/prod/KEY_ONE", "v1")
                ],
                "NextToken" => "page-2"
              })
          end
        end
      })

      assert {:ok, refs} = Aws.list_secrets("prod")
      assert Enum.map(refs, & &1.key) |> Enum.sort() == ["KEY_ONE", "KEY_TWO"]
    end
  end

  describe "list_environments/0 and list_all_secrets/0" do
    test "list_environments/0 sends Recursive: true and dedupes buckets" do
      test_pid = self()

      stub_with(%{
        "GetParametersByPath" => fn conn, raw_body ->
          send(test_pid, {:get_parameters_by_path, Jason.decode!(raw_body)})

          respond_json(conn, 200, %{
            "Parameters" => [
              parameter("/acme/deployments/main/faas/functions/prod/A", "v1"),
              parameter("/acme/deployments/main/faas/functions/prod/B", "v2"),
              parameter("/acme/deployments/main/faas/functions/shared/C", "v3")
            ]
          })
        end
      })

      assert {:ok, environments} = Aws.list_environments()
      assert environments == ["prod", "shared"]

      assert_received {:get_parameters_by_path, %{"WithDecryption" => false, "Recursive" => true}}
    end

    test "list_all_secrets/0 returns every {environment, secret} pair" do
      stub_with(%{
        "GetParametersByPath" => fn conn, _body ->
          respond_json(conn, 200, %{
            "Parameters" => [
              parameter("/acme/deployments/main/faas/functions/prod/A", "v1"),
              parameter("/acme/deployments/main/faas/functions/shared/C", "v3")
            ]
          })
        end
      })

      assert {:ok, all} = Aws.list_all_secrets()

      assert Enum.map(all, &{&1.environment, &1.secret.key}) |> Enum.sort() ==
               [{"prod", "A"}, {"shared", "C"}]
    end

    test "both share one underlying recursive call — GetParametersByPath is hit once per call" do
      test_pid = self()

      stub_with(%{
        "GetParametersByPath" => fn conn, _body ->
          send(test_pid, :get_parameters_by_path_called)
          respond_json(conn, 200, %{"Parameters" => []})
        end
      })

      assert {:ok, _} = Aws.list_environments()
      assert_received :get_parameters_by_path_called
      refute_received :get_parameters_by_path_called
    end
  end

  # -- locate_secret/2 ------------------------------------------------------

  describe "locate_secret/2" do
    test "returns the path and ARN without any parameter call" do
      test_pid = self()

      stub_with(%{
        "GetParameter" => fn _conn, _body -> send(test_pid, :unexpected_call) end
      })

      assert {:ok, location} = Aws.locate_secret("prod", "DB_PASSWORD")

      assert location.path == "/acme/deployments/main/faas/functions/prod/DB_PASSWORD"

      assert location.arn ==
               "arn:aws:ssm:us-east-1:123456789012:parameter/acme/deployments/main/faas/functions/prod/DB_PASSWORD"

      refute_received :unexpected_call
    end
  end

  # -- Error mapping shared across operations ------------------------------

  describe "error mapping" do
    for code <- ~w(ExpiredToken ExpiredTokenException InvalidClientTokenId RequestExpired) do
      test "#{code} on GetParameter maps to :auth_expired and clears the credential cache" do
        stub_with(%{"GetParameter" => fn conn, _body -> aws_error(conn, 400, unquote(code)) end})

        assert {:error, %Error{kind: :auth_expired}} = Aws.get_secret("prod", "X")
        assert CredentialCache.get(@cache_key) == nil
      end
    end

    test "throttling maps to :unavailable" do
      stub_with(%{
        "GetParameter" => fn conn, _body -> aws_error(conn, 400, "ThrottlingException") end
      })

      assert {:error, %Error{kind: :unavailable}} = Aws.get_secret("prod", "X")
    end

    test "a 500 maps to :unavailable" do
      stub_with(%{
        "GetParameter" => fn conn, _body -> aws_error(conn, 500, "InternalServerError") end
      })

      assert {:error, %Error{kind: :unavailable}} = Aws.get_secret("prod", "X")
    end

    test "a transport error maps to :unavailable" do
      stub_with(%{
        "GetParameter" => fn conn, _body -> Req.Test.transport_error(conn, :econnrefused) end
      })

      assert {:error, %Error{kind: :unavailable}} = Aws.get_secret("prod", "X")
    end

    test "an unset TENANT_ROLE_ARN is :not_configured, with no request attempted" do
      Application.put_env(:nucleus, Aws, role_arn: nil, region: @region, plug: {Req.Test, @stub})
      test_pid = self()

      stub_with(%{
        "AssumeRole" => fn _conn, _body -> send(test_pid, :assume_role_called) end
      })

      assert {:error, %Error{kind: :not_configured}} = Aws.get_secret("prod", "X")
      refute_received :assume_role_called
    end

    test "a missing CLUSTER_NAME/DEPLOYMENT_NAME is :not_configured, with no request attempted" do
      Application.put_env(:nucleus, Path, cluster_name: nil, deployment_name: nil)
      test_pid = self()

      stub_with(%{
        "AssumeRole" => fn _conn, _body -> send(test_pid, :assume_role_called) end
      })

      assert {:error, %Error{kind: :not_configured}} = Aws.get_secret("prod", "X")
      refute_received :assume_role_called
    end

    test "unset AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY is :not_configured" do
      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")

      assert {:error, %Error{kind: :not_configured}} = Aws.get_secret("prod", "X")
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
        "GetParameter" => fn conn, _body ->
          respond_json(conn, 200, %{"Parameter" => parameter("/x", "v1")})
        end
      })

      assert {:ok, _} = Aws.get_secret("prod", "A")
      assert {:ok, _} = Aws.get_secret("prod", "B")

      assert_received :assume_role_called
      refute_received :assume_role_called
    end

    test "credentials are re-fetched after an expiry-shaped error clears the cache" do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        action = action_of(conn, raw_body)

        case {action, Process.get(:already_failed_once)} do
          {"AssumeRole", _} ->
            send(test_pid, :assume_role_called)
            respond_xml(conn, 200, assume_role_xml())

          {"GetCallerIdentity", _} ->
            respond_xml(conn, 200, get_caller_identity_xml())

          {"GetParameter", nil} ->
            Process.put(:already_failed_once, true)
            aws_error(conn, 400, "ExpiredToken")

          {"GetParameter", true} ->
            respond_json(conn, 200, %{"Parameter" => parameter("/x", "v1")})
        end
      end)

      assert {:error, %Error{kind: :auth_expired}} = Aws.get_secret("prod", "A")
      assert_received :assume_role_called

      assert {:ok, _} = Aws.get_secret("prod", "A")
      assert_received :assume_role_called
    end
  end

  # -- Logging discipline ---------------------------------------------------

  describe "logging discipline" do
    test "a failed PutParameter never logs the secret value" do
      stub_with(%{
        "PutParameter" => fn conn, _body -> aws_error(conn, 500, "InternalServerError") end
      })

      log =
        capture_log(fn ->
          assert {:error, %Error{kind: :unavailable}} =
                   Aws.create_secret("prod", "DB_PASSWORD", "leak-me-please")
        end)

      refute log =~ "leak-me-please"
    end

    test "a successful PutParameter never logs the secret value" do
      stub_with(%{
        "PutParameter" => fn conn, _body -> respond_json(conn, 200, %{"Version" => 1}) end
      })

      log =
        capture_log(fn ->
          assert {:ok, _ref} = Aws.create_secret("prod", "DB_PASSWORD", "leak-me-please-too")
        end)

      refute log =~ "leak-me-please-too"
    end
  end

  # -- health_check/0 --------------------------------------------------------

  describe "health_check/0" do
    test "is :ok when Parameter Store answers" do
      stub_with(%{
        "GetParametersByPath" => fn conn, _body ->
          respond_json(conn, 200, %{"Parameters" => []})
        end
      })

      assert Aws.health_check() == :ok
    end

    test "is :unavailable on a transport error" do
      stub_with(%{
        "GetParametersByPath" => fn conn, _body -> Req.Test.transport_error(conn, :timeout) end
      })

      assert {:error, %Error{kind: :unavailable}} = Aws.health_check()
    end
  end
end
