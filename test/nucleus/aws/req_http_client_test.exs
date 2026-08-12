defmodule Nucleus.Aws.ReqHttpClientTest do
  use ExUnit.Case, async: false

  alias Nucleus.Aws.ReqHttpClient

  @stub __MODULE__

  defp stub(fun), do: Req.Test.stub(@stub, fun)

  describe "request/5" do
    test "satisfies the AWS.HTTPClient behaviour" do
      assert AWS.HTTPClient in (ReqHttpClient.__info__(:attributes)[:behaviour] || [])
    end

    test "dispatches through Req, returning {:ok, %{status_code:, headers:, body:}}" do
      stub(fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/"
        Plug.Conn.resp(conn, 200, "hello")
      end)

      assert {:ok, %{status_code: 200, headers: headers, body: "hello"}} =
               ReqHttpClient.request(:post, "https://example.com/", "payload", [],
                 plug: {Req.Test, @stub}
               )

      assert is_list(headers)
      assert Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end)
    end

    test "carries request headers through verbatim" do
      stub(fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-amz-target") == ["AmazonSSM.GetParameter"]
        Plug.Conn.resp(conn, 200, "")
      end)

      assert {:ok, _} =
               ReqHttpClient.request(
                 :post,
                 "https://example.com/",
                 "",
                 [{"x-amz-target", "AmazonSSM.GetParameter"}],
                 plug: {Req.Test, @stub}
               )
    end

    test "flattens Req's map-of-lists response headers into a list of tuples" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-amzn-errortype", "ParameterNotFound")
        |> Plug.Conn.resp(400, "{}")
      end)

      assert {:ok, %{headers: headers}} =
               ReqHttpClient.request(:post, "https://example.com/", "", [],
                 plug: {Req.Test, @stub}
               )

      assert {"x-amzn-errortype", "ParameterNotFound"} in headers
    end

    test "re-shapes a timeout transport error to match AWS.Client's retry pattern" do
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %{reason: :timeout}} =
               ReqHttpClient.request(:post, "https://example.com/", "", [],
                 plug: {Req.Test, @stub}
               )
    end

    test "re-shapes a closed transport error to match AWS.Client's retry pattern" do
      stub(fn conn -> Req.Test.transport_error(conn, :closed) end)

      assert {:error, %{reason: :closed}} =
               ReqHttpClient.request(:post, "https://example.com/", "", [],
                 plug: {Req.Test, @stub}
               )
    end

    test "other transport errors pass through as-is" do
      stub(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               ReqHttpClient.request(:post, "https://example.com/", "", [],
                 plug: {Req.Test, @stub}
               )
    end

    test "never logs anything, in either branch" do
      stub(fn conn -> Plug.Conn.resp(conn, 500, "request body was: leak-me-please") end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          ReqHttpClient.request(:post, "https://example.com/", "leak-me-please", [],
            plug: {Req.Test, @stub}
          )
        end)

      assert log == ""
    end
  end
end
