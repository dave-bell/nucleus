defmodule Nucleus.NomadVars.Store.HttpTest do
  # Configuration is application-global, so these cannot run concurrently.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Nucleus.Backend.Error
  alias Nucleus.NomadVars.Path
  alias Nucleus.NomadVars.Store.Http
  alias Nucleus.NomadVars.VariableSet

  @stub __MODULE__

  setup do
    original = Application.get_env(:nucleus, Nucleus.Nomad.Transport)
    on_exit(fn -> Application.put_env(:nucleus, Nucleus.Nomad.Transport, original) end)
    :ok
  end

  defp configure(overrides \\ []) do
    Application.put_env(
      :nucleus,
      Nucleus.Nomad.Transport,
      Keyword.merge(
        [base_url: "https://nomad.example.com", plug: {Req.Test, @stub}],
        overrides
      )
    )
  end

  defp stub(fun), do: Req.Test.stub(@stub, fun)

  defp json(conn, data), do: Req.Test.json(conn, data)

  defp expected_request_path, do: "/v1/var/" <> Path.path()

  defp variable_body(attrs \\ %{}) do
    Map.merge(
      %{
        "Namespace" => "default",
        "Path" => Path.path(),
        "Items" => %{"description" => "a nightly export"},
        "CreateIndex" => 10,
        "ModifyIndex" => 42,
        "CreateTime" => 1_754_000_000_000_000_000,
        "ModifyTime" => 1_754_000_000_000_000_000
      },
      attrs
    )
  end

  describe "read/0" do
    test "requests the tenant's Data Export variable path" do
      configure()

      stub(fn conn ->
        assert conn.request_path == expected_request_path()
        assert conn.method == "GET"
        json(conn, variable_body())
      end)

      assert {:ok, %VariableSet{} = variable_set} = Http.read()
      assert variable_set.path == Path.path()
      assert variable_set.items == %{"description" => "a nightly export"}
      assert variable_set.modify_index == 42
      assert %DateTime{} = variable_set.modified_at
    end

    test "a missing path is :not_found — the tenant's enablement signal" do
      configure()
      stub(fn conn -> Plug.Conn.resp(conn, 404, "{}") end)

      assert {:error, %Error{kind: :not_found, boundary: :nomad_vars}} = Http.read()
    end

    test "an unexpected shape (no ModifyIndex) is :unavailable" do
      configure()
      stub(fn conn -> json(conn, %{"unexpected" => "shape"}) end)

      assert {:error, %Error{kind: :unavailable, boundary: :nomad_vars}} = Http.read()
    end
  end

  describe "write/2" do
    test "sends a PUT with the cas query param and the encoded Items body" do
      configure()

      stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == expected_request_path()
        assert Plug.Conn.fetch_query_params(conn).query_params["cas"] == "42"

        {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw_body) == %{"Items" => %{"description" => "updated"}}

        json(
          conn,
          variable_body(%{"Items" => %{"description" => "updated"}, "ModifyIndex" => 43})
        )
      end)

      assert {:ok, %VariableSet{} = variable_set} =
               Http.write(%{"description" => "updated"}, 42)

      assert variable_set.items == %{"description" => "updated"}
      assert variable_set.modify_index == 43
    end

    test "a stale modify index is :conflict, carrying the fresh ModifyIndex" do
      configure()

      stub(fn conn ->
        assert Plug.Conn.fetch_query_params(conn).query_params["cas"] == "1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(409, Jason.encode!(variable_body(%{"ModifyIndex" => 99})))
      end)

      assert {:error, %Error{kind: :conflict, details: details}} =
               Http.write(%{"description" => "stale"}, 1)

      assert details.modify_index == 99
    end

    test "an empty-body success falls back to a fresh read/0" do
      configure()
      expected_path = expected_request_path()

      stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"PUT", ^expected_path} ->
            Plug.Conn.resp(conn, 200, "")

          {"GET", ^expected_path} ->
            json(conn, variable_body(%{"ModifyIndex" => 43}))
        end
      end)

      assert {:ok, %VariableSet{modify_index: 43}} = Http.write(%{"description" => "x"}, 42)
    end
  end

  describe "health_check/0" do
    test "is :ok when the path is readable" do
      configure()
      stub(fn conn -> json(conn, variable_body()) end)

      assert Http.health_check() == :ok
    end

    test "is :ok on 404 — reachability, not enablement" do
      configure()
      stub(fn conn -> Plug.Conn.resp(conn, 404, "{}") end)

      assert Http.health_check() == :ok
    end

    for status <- [401, 403] do
      test "is :ok on #{status} — reachability, not permission" do
        configure()
        stub(fn conn -> Plug.Conn.resp(conn, unquote(status), "{}") end)

        assert Http.health_check() == :ok
      end
    end

    test "is :unavailable on 500" do
      configure()
      stub(fn conn -> Plug.Conn.resp(conn, 500, "{}") end)

      assert {:error, %Error{kind: :unavailable}} = Http.health_check()
    end

    test "is :not_configured with no base URL" do
      configure(base_url: nil)

      assert {:error, %Error{kind: :not_configured}} = Http.health_check()
    end
  end
end
