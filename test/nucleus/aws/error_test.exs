defmodule Nucleus.Aws.ErrorTest do
  # Credential-cache clearing touches :persistent_term (global to the node).
  use ExUnit.Case, async: false

  alias Nucleus.Aws.CredentialCache
  alias Nucleus.Aws.Error, as: AwsError
  alias Nucleus.Backend.Error

  @cache_key {"arn:aws:iam::123456789012:role/TenantRole", nil, "nucleus-secrets"}

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        boundary: :secrets,
        cache_key: @cache_key,
        codes: %{
          "ParameterNotFound" => :not_found,
          "ParameterAlreadyExists" => :already_exists
        },
        transport_message: "the tenant's AWS account is unreachable"
      },
      overrides
    )
  end

  setup do
    CredentialCache.put(@cache_key, %{some: :credentials})
    :ok
  end

  # -- classify/3 — order-sensitive table -----------------------------------

  describe "classify/3 order" do
    for code <- ~w(ExpiredToken ExpiredTokenException InvalidClientTokenId RequestExpired) do
      test "#{code} classifies as :auth_expired and clears the cache slot named by cache_key" do
        assert %Error{kind: :auth_expired, boundary: :secrets} =
                 AwsError.classify({:aws_error, 400, unquote(code)}, ctx(), "req-1")

        assert CredentialCache.get(@cache_key) == nil
      end
    end

    for code <- ~w(AccessDenied AccessDeniedException) do
      test "#{code} classifies as :auth_expired and does not clear the cache" do
        assert %Error{kind: :auth_expired} =
                 AwsError.classify({:aws_error, 403, unquote(code)}, ctx(), "req-1")

        assert CredentialCache.get(@cache_key) != nil
      end
    end

    test "an adapter code map entry is consulted, with the adapter's kind" do
      assert %Error{kind: :not_found, boundary: :secrets} =
               AwsError.classify({:aws_error, 400, "ParameterNotFound"}, ctx(), "req-1")

      assert %Error{kind: :already_exists} =
               AwsError.classify({:aws_error, 400, "ParameterAlreadyExists"}, ctx(), "req-1")
    end

    test "an adapter code map cannot shadow the expired-credential rule" do
      shadowing_ctx = ctx(%{codes: %{"ExpiredToken" => :not_found}})

      assert %Error{kind: :auth_expired} =
               AwsError.classify({:aws_error, 400, "ExpiredToken"}, shadowing_ctx, "req-1")

      assert CredentialCache.get(@cache_key) == nil
    end

    for code <- ~w(ThrottlingException Throttling TooManyRequestsException) do
      test "#{code} classifies as :unavailable" do
        assert %Error{kind: :unavailable} =
                 AwsError.classify({:aws_error, 400, unquote(code)}, ctx(), "req-1")
      end
    end

    test "HTTP 429 classifies as :unavailable even with an unrecognised code" do
      assert %Error{kind: :unavailable} =
               AwsError.classify({:aws_error, 429, "SomeOtherCode"}, ctx(), "req-1")
    end

    test "HTTP 5xx classifies as :unavailable even with an unrecognised code" do
      assert %Error{kind: :unavailable} =
               AwsError.classify({:aws_error, 503, "InternalFailure"}, ctx(), "req-1")
    end

    test "an unrecognised code with a non-5xx, non-429 status is still :unavailable" do
      assert %Error{kind: :unavailable, boundary: :secrets} =
               AwsError.classify({:aws_error, 400, "SomeOtherCode"}, ctx(), "req-1")
    end

    test "a transport error classifies as :unavailable with ctx.transport_message" do
      assert %Error{kind: :unavailable, message: "the tenant's AWS account is unreachable"} =
               AwsError.classify({:transport_error, %{reason: :econnrefused}}, ctx(), "req-1")
    end

    test "a transport error uses the boundary-specific message passed in via ctx" do
      m2m_ctx =
        ctx(%{boundary: :m2m, transport_message: "the platform's AWS account is unreachable"})

      assert %Error{
               kind: :unavailable,
               boundary: :m2m,
               message: "the platform's AWS account is unreachable"
             } =
               AwsError.classify({:transport_error, :timeout}, m2m_ctx, "req-1")
    end

    test "details carry the request_id for correlation" do
      assert %Error{details: %{request_id: "req-42"}} =
               AwsError.classify({:aws_error, 400, "ExpiredToken"}, ctx(), "req-42")
    end
  end

  # -- as_backend_result/3 ----------------------------------------------------

  describe "as_backend_result/3" do
    test "passes an :ok result through unchanged" do
      assert {:ok, %{"Parameter" => "value"}} =
               AwsError.as_backend_result({:ok, %{"Parameter" => "value"}}, ctx(), "req-1")
    end

    test "classifies an :error result into a Nucleus.Backend.Error" do
      assert {:error, %Error{kind: :not_found}} =
               AwsError.as_backend_result(
                 {:error, {:aws_error, 400, "ParameterNotFound"}},
                 ctx(),
                 "req-1"
               )
    end
  end

  # -- unwrap/2 ----------------------------------------------------------------

  describe "unwrap/2" do
    setup do
      {:ok, client: AWS.Client.create("AKIAEXAMPLE", "secretexample", nil, "us-east-1")}
    end

    test "an ok result unwraps to {:ok, body}", %{client: client} do
      assert {:ok, %{"Value" => "v"}} = AwsError.unwrap(client, {:ok, %{"Value" => "v"}, %{}})
    end

    test "a JSON error body extracts the error code via __type", %{client: client} do
      response = %{
        status_code: 400,
        headers: [{"content-type", "application/x-amz-json-1.1"}],
        body: Jason.encode!(%{"__type" => "ParameterNotFound", "message" => "boom"})
      }

      assert {:error, {:aws_error, 400, "ParameterNotFound"}} =
               AwsError.unwrap(client, {:error, {:unexpected_response, response}})
    end

    test "the x-amzn-errortype header takes priority over the decoded body", %{client: client} do
      response = %{
        status_code: 400,
        headers: [
          {"x-amzn-errortype", "AccessDeniedException"},
          {"content-type", "application/x-amz-json-1.1"}
        ],
        body: Jason.encode!(%{"__type" => "ParameterNotFound"})
      }

      assert {:error, {:aws_error, 400, "AccessDeniedException"}} =
               AwsError.unwrap(client, {:error, {:unexpected_response, response}})
    end

    test "a namespaced error type is trimmed to its tail", %{client: client} do
      response = %{
        status_code: 400,
        headers: [{"x-amzn-errortype", "com.amazon.coral.service#ExpiredTokenException"}],
        body: ""
      }

      assert {:error, {:aws_error, 400, "ExpiredTokenException"}} =
               AwsError.unwrap(client, {:error, {:unexpected_response, response}})
    end

    test "an XML error body extracts Error/Code", %{client: client} do
      xml = """
      <Error>
        <Code>ExpiredToken</Code>
        <Message>boom</Message>
      </Error>
      """

      response = %{
        status_code: 400,
        headers: [{"content-type", "text/xml"}],
        body: xml
      }

      assert {:error, {:aws_error, 400, "ExpiredToken"}} =
               AwsError.unwrap(client, {:error, {:unexpected_response, response}})
    end

    test "an XML body with no Error/Code yields a nil code rather than crashing", %{
      client: client
    } do
      response = %{
        status_code: 500,
        headers: [{"content-type", "text/xml"}],
        body: "<SomethingElse></SomethingElse>"
      }

      assert {:error, {:aws_error, 500, nil}} =
               AwsError.unwrap(client, {:error, {:unexpected_response, response}})
    end

    test "a transport failure (no AWS response) unwraps to {:transport_error, reason}", %{
      client: client
    } do
      assert {:error, {:transport_error, :econnrefused}} =
               AwsError.unwrap(client, {:error, :econnrefused})
    end
  end
end
