defmodule Nucleus.NomadJobs.HttpTest do
  # Configuration is application-global, so these cannot run concurrently.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Nucleus.Backend.Error
  alias Nucleus.NomadJobs.Http

  @stub __MODULE__
  @namespace "local"

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

  defp stub_by_path(routes) do
    stub(fn conn ->
      case Map.fetch(routes, conn.request_path) do
        {:ok, fun} -> fun.(conn)
        :error -> flunk("unexpected request to #{conn.request_path}")
      end
    end)
  end

  defp list_stub(id, attrs \\ %{}) do
    Map.merge(
      %{"ID" => id, "ParentID" => nil, "Name" => id, "Status" => "running", "Periodic" => false},
      attrs
    )
  end

  defp detail(attrs \\ %{}) do
    Map.merge(
      %{
        "Version" => 1,
        "Periodic" => nil,
        "TaskGroups" => [
          %{
            "Tasks" => [
              %{
                "Name" => "primary",
                "Lifecycle" => nil,
                "Leader" => true,
                "Config" => %{"image" => "registry.example.com/acme/primary:v1.0.0"}
              }
            ]
          }
        ]
      },
      attrs
    )
  end

  describe "list_jobs/1" do
    test "lists then fans out one detail call per parent" do
      configure()

      stub_by_path(%{
        "/v1/jobs" => &json(&1, [list_stub("api")]),
        "/v1/job/api" => &json(&1, detail())
      })

      assert {:ok, [job]} = Http.list_jobs(@namespace)
      assert job.name == "api"
      assert job.namespace == @namespace
    end

    test "sends the namespace as a query parameter on both calls" do
      configure()

      stub(fn conn ->
        assert Plug.Conn.fetch_query_params(conn).query_params["namespace"] == @namespace

        case conn.request_path do
          "/v1/jobs" -> json(conn, [list_stub("api")])
          "/v1/job/api" -> json(conn, detail())
        end
      end)

      assert {:ok, [_job]} = Http.list_jobs(@namespace)
    end

    test "children — periodic and dispatch alike — are excluded before the fan-out" do
      configure()

      test_pid = self()

      stub(fn conn ->
        case conn.request_path do
          "/v1/jobs" ->
            json(conn, [
              list_stub("parent", %{"Periodic" => true}),
              list_stub("parent/periodic-1", %{"ParentID" => "parent"}),
              list_stub("other-parent"),
              list_stub("other-parent/dispatch-1", %{"ParentID" => "other-parent"})
            ])

          "/v1/job/" <> id ->
            send(test_pid, {:detail_requested, id})
            json(conn, detail())
        end
      end)

      assert {:ok, jobs} = Http.list_jobs(@namespace)
      names = Enum.map(jobs, & &1.name)

      assert "parent" in names
      assert "other-parent" in names
      refute "parent/periodic-1" in names
      refute "other-parent/dispatch-1" in names

      assert_received {:detail_requested, "parent"}
      assert_received {:detail_requested, "other-parent"}
      refute_received {:detail_requested, "parent/periodic-1"}
      refute_received {:detail_requested, "other-parent/dispatch-1"}
    end

    test "version is read from the detail response — it would be nil if read from the list stub" do
      configure()

      stub_by_path(%{
        "/v1/jobs" => &json(&1, [list_stub("api")]),
        "/v1/job/api" => &json(&1, detail(%{"Version" => 42}))
      })

      assert {:ok, [job]} = Http.list_jobs(@namespace)
      # The list stub carries no Version field at all — this assertion fails
      # if the implementation ever reads Version from the list response
      # instead of the detail response (the prototype's nomad.py:139 bug).
      assert job.version == 42
    end

    test "the image comes from the primary task, not a leading prestart task or an injected sidecar" do
      configure()

      task_shaped_detail =
        detail(%{
          "TaskGroups" => [
            %{
              "Tasks" => [
                %{
                  "Name" => "migrate",
                  "Lifecycle" => %{"Hook" => "prestart", "Sidecar" => false},
                  "Leader" => false,
                  "Config" => %{"image" => "registry.example.com/acme/migrate:sha-aaa"}
                },
                %{
                  "Name" => "api",
                  "Lifecycle" => nil,
                  "Leader" => true,
                  "Config" => %{"image" => "registry.example.com/acme/api:v1.4.0"}
                },
                %{
                  "Name" => "connect-proxy-api",
                  "Lifecycle" => %{"Hook" => "prestart", "Sidecar" => true},
                  "Leader" => false,
                  "Config" => %{"image" => "envoyproxy/envoy:v1.29.0"}
                }
              ]
            }
          ]
        })

      stub_by_path(%{
        "/v1/jobs" => &json(&1, [list_stub("api")]),
        "/v1/job/api" => &json(&1, task_shaped_detail)
      })

      assert {:ok, [job]} = Http.list_jobs(@namespace)
      assert job.image == "registry.example.com/acme/api:v1.4.0"
    end

    test "one failing detail call degrades only that row" do
      configure()

      stub(fn conn ->
        case conn.request_path do
          "/v1/jobs" ->
            json(conn, [list_stub("healthy"), list_stub("unhealthy")])

          "/v1/job/healthy" ->
            json(conn, detail())

          "/v1/job/unhealthy" ->
            Plug.Conn.resp(conn, 500, "{}")
        end
      end)

      assert {:ok, jobs} = Http.list_jobs(@namespace)

      healthy = Enum.find(jobs, &(&1.name == "healthy"))
      unhealthy = Enum.find(jobs, &(&1.name == "unhealthy"))

      assert healthy.detail_error == nil
      assert is_integer(healthy.version)

      assert unhealthy.detail_error == :unavailable
      assert unhealthy.version == nil
      assert unhealthy.image == nil
      assert unhealthy.cron == nil
      # The degraded row still carries its list-stub fields.
      assert unhealthy.name == "unhealthy"
      assert unhealthy.status == "running"
    end

    test "a failing list call fails the whole operation" do
      configure()
      stub(fn conn -> Plug.Conn.resp(conn, 500, "{}") end)

      assert {:error, %Error{kind: :unavailable, boundary: :nomad_jobs}} =
               Http.list_jobs(@namespace)
    end
  end

  describe "health_check/0" do
    test "is :ok on 200" do
      configure()
      stub(fn conn -> json(conn, []) end)

      assert Http.health_check() == :ok
    end

    for status <- [401, 403] do
      test "is :ok on #{status} — reachability, not permission" do
        configure()
        stub(fn conn -> Plug.Conn.resp(conn, unquote(status), "{}") end)

        assert Http.health_check() == :ok
      end
    end

    for status <- [500, 502, 503] do
      test "is :unavailable on #{status}" do
        configure()
        stub(fn conn -> Plug.Conn.resp(conn, unquote(status), "{}") end)

        assert {:error, %Error{kind: :unavailable}} = Http.health_check()
      end
    end

    test "is :unavailable on a transport error" do
      configure()
      stub(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Error{kind: :unavailable}} = Http.health_check()
    end

    test "is :not_configured with no base URL" do
      configure(base_url: nil)

      assert {:error, %Error{kind: :not_configured}} = Http.health_check()
    end
  end
end
