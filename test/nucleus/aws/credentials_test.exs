defmodule Nucleus.Aws.CredentialsTest do
  # Credentials are cached in :persistent_term (global to the node), so these
  # cannot run concurrently.
  use ExUnit.Case, async: false

  alias Nucleus.Aws.CredentialCache
  alias Nucleus.Aws.Credentials
  alias Nucleus.Backend.Error

  @stub __MODULE__
  @role_arn "arn:aws:iam::123456789012:role/TenantRole"
  @other_role_arn "arn:aws:iam::123456789012:role/OtherRole"
  @account_id "123456789012"
  @region "us-east-1"
  @session_name "nucleus-test"

  setup do
    original_access_key = System.get_env("AWS_ACCESS_KEY_ID")
    original_secret_key = System.get_env("AWS_SECRET_ACCESS_KEY")
    original_session_token = System.get_env("AWS_SESSION_TOKEN")

    System.put_env("AWS_ACCESS_KEY_ID", "AKIAOWNEXAMPLE")
    System.put_env("AWS_SECRET_ACCESS_KEY", "ownsecretexample")
    System.delete_env("AWS_SESSION_TOKEN")

    CredentialCache.clear(cache_key(@role_arn))
    CredentialCache.clear(cache_key(@other_role_arn))

    on_exit(fn ->
      restore_env("AWS_ACCESS_KEY_ID", original_access_key)
      restore_env("AWS_SECRET_ACCESS_KEY", original_secret_key)
      restore_env("AWS_SESSION_TOKEN", original_session_token)
      CredentialCache.clear(cache_key(@role_arn))
      CredentialCache.clear(cache_key(@other_role_arn))
    end)

    :ok
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp cache_key(role_arn), do: {role_arn, nil, @session_name}

  defp spec(overrides \\ %{}) do
    Map.merge(
      %{
        boundary: :secrets,
        role_arn: @role_arn,
        region: @region,
        external_id: nil,
        session_name: @session_name,
        http_client_opts: [plug: {Req.Test, @stub}]
      },
      overrides
    )
  end

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
          <Arn>arn:aws:sts::#{@account_id}:assumed-role/TenantRole/#{@session_name}</Arn>
          <AssumedRoleId>AROAEXAMPLE:#{@session_name}</AssumedRoleId>
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
        <Arn>arn:aws:sts::#{@account_id}:assumed-role/TenantRole/#{@session_name}</Arn>
        <UserId>AROAEXAMPLE:#{@session_name}</UserId>
        <Account>#{@account_id}</Account>
      </GetCallerIdentityResult>
      <ResponseMetadata>
        <RequestId>req-get-caller-identity</RequestId>
      </ResponseMetadata>
    </GetCallerIdentityResponse>
    """
  end

  describe "fetch/1" do
    test "assumes the role and returns a client plus the account id" do
      stub_with(%{})

      assert {:ok, %{client: %AWS.Client{}, account_id: @account_id}} = Credentials.fetch(spec())
    end

    test "a cache hit inside expiry does not re-assume" do
      test_pid = self()

      stub_with(%{
        "AssumeRole" => fn conn, _body ->
          send(test_pid, :assume_role_called)
          respond_xml(conn, 200, assume_role_xml())
        end
      })

      assert {:ok, _} = Credentials.fetch(spec())
      assert {:ok, _} = Credentials.fetch(spec())

      assert_received :assume_role_called
      refute_received :assume_role_called
    end

    test "a cache miss past expiry re-assumes" do
      test_pid = self()

      stub_with(%{
        "AssumeRole" => fn conn, _body ->
          send(test_pid, :assume_role_called)

          expiration = DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
          respond_xml(conn, 200, assume_role_xml(expiration: expiration))
        end
      })

      assert {:ok, _} = Credentials.fetch(spec())
      assert_received :assume_role_called

      assert {:ok, _} = Credentials.fetch(spec())
      assert_received :assume_role_called
    end

    test "an unparseable Expiration is treated as already-expired" do
      test_pid = self()

      stub_with(%{
        "AssumeRole" => fn conn, _body ->
          send(test_pid, :assume_role_called)
          respond_xml(conn, 200, assume_role_xml(expiration: "not-a-timestamp"))
        end
      })

      assert {:ok, _} = Credentials.fetch(spec())
      assert_received :assume_role_called

      assert {:ok, _} = Credentials.fetch(spec())
      assert_received :assume_role_called
    end

    test "the STS XML envelope unwraps into flat AccessKeyId/Account fields" do
      stub_with(%{})

      assert {:ok, %{account_id: @account_id}} = Credentials.fetch(spec())
    end

    test "a missing key pair returns :not_configured, with no request attempted" do
      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")

      test_pid = self()

      stub_with(%{
        "AssumeRole" => fn _conn, _body -> send(test_pid, :assume_role_called) end
      })

      assert {:error, %Error{kind: :not_configured}} = Credentials.fetch(spec())
      refute_received :assume_role_called
    end

    test "the returned error carries the boundary it was called with" do
      System.delete_env("AWS_ACCESS_KEY_ID")
      System.delete_env("AWS_SECRET_ACCESS_KEY")

      assert {:error, %Error{boundary: :m2m}} = Credentials.fetch(spec(%{boundary: :m2m}))
    end
  end

  describe "cache keying" do
    test "two specs with different role_arns get two slots and one AssumeRole each" do
      test_pid = self()

      stub_with(%{
        "AssumeRole" => fn conn, raw_body ->
          role_arn = raw_body |> URI.decode_query() |> Map.get("RoleArn")
          send(test_pid, {:assume_role_called, role_arn})
          respond_xml(conn, 200, assume_role_xml())
        end
      })

      assert {:ok, _} = Credentials.fetch(spec())
      assert {:ok, _} = Credentials.fetch(spec(%{role_arn: @other_role_arn}))

      assert_received {:assume_role_called, @role_arn}
      assert_received {:assume_role_called, @other_role_arn}
      refute_received {:assume_role_called, _}

      # both are now cached; a second round trip for each hits its own slot.
      assert {:ok, _} = Credentials.fetch(spec())
      assert {:ok, _} = Credentials.fetch(spec(%{role_arn: @other_role_arn}))
      refute_received {:assume_role_called, _}
    end

    test "two identical specs share one slot and produce exactly one AssumeRole" do
      test_pid = self()

      stub_with(%{
        "AssumeRole" => fn conn, _body ->
          send(test_pid, :assume_role_called)
          respond_xml(conn, 200, assume_role_xml())
        end
      })

      assert {:ok, _} = Credentials.fetch(spec(%{boundary: :secrets}))
      assert {:ok, _} = Credentials.fetch(spec(%{boundary: :m2m}))

      assert_received :assume_role_called
      refute_received :assume_role_called
    end

    test "expiry on one slot clears that slot and leaves the other intact" do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        action = action_of(conn, raw_body)
        role_arn = raw_body |> URI.decode_query() |> Map.get("RoleArn")

        case {action, role_arn} do
          {"AssumeRole", ^role_arn} ->
            send(test_pid, {:assume_role_called, role_arn})

            expiration =
              if role_arn == @role_arn do
                DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
              else
                DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
              end

            respond_xml(conn, 200, assume_role_xml(expiration: expiration))

          {"GetCallerIdentity", _} ->
            respond_xml(conn, 200, get_caller_identity_xml())
        end
      end)

      # Prime both slots.
      assert {:ok, _} = Credentials.fetch(spec())
      assert {:ok, _} = Credentials.fetch(spec(%{role_arn: @other_role_arn}))
      assert_received {:assume_role_called, @role_arn}
      assert_received {:assume_role_called, @other_role_arn}

      # @role_arn's credentials are already-expired (expiration in the
      # past), so fetching it again re-assumes; @other_role_arn's slot is
      # untouched and does not.
      assert {:ok, _} = Credentials.fetch(spec())
      assert_received {:assume_role_called, @role_arn}

      assert {:ok, _} = Credentials.fetch(spec(%{role_arn: @other_role_arn}))
      refute_received {:assume_role_called, @other_role_arn}
    end
  end
end
