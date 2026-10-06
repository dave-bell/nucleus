defmodule Nucleus.TenantApi.ServiceTokenTest do
  # The driver reads a script from application config, which is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nucleus.Backend.Error
  alias Nucleus.TenantApi.ServiceToken

  defmodule Issuer do
    @moduledoc false
    # A `:service_token` driver that plays back a script of results. It runs in
    # the cache's fetch task, so the script lives in an Agent and the test learns
    # of each request by message.
    @behaviour Nucleus.TenantApi.ServiceToken

    @impl true
    def request_token do
      {pid, script} = Application.fetch_env!(:nucleus, :service_token_test)
      send(pid, {:requested, self()})

      case Agent.get_and_update(script, fn
             [next | rest] -> {next, rest}
             [] -> {{:ok, %{token: "default", expires_in: 3_600}}, []}
           end) do
        :block ->
          receive do
            {:release, result} -> result
          end

        :raise ->
          raise "the issuer blew up"

        result ->
          result
      end
    end

    @impl true
    def health_check, do: :ok
  end

  @cache :service_token_under_test

  setup do
    script = start_supervised!({Agent, fn -> [] end})
    clock = start_supervised!({Agent, fn -> 0 end}, id: :clock)

    Application.put_env(:nucleus, :service_token_test, {self(), script})
    on_exit(fn -> Application.delete_env(:nucleus, :service_token_test) end)

    start_supervised!(
      {ServiceToken, name: @cache, driver: Issuer, clock: fn -> Agent.get(clock, & &1) end}
    )

    %{script: script, clock: clock}
  end

  defp script(ctx, results), do: Agent.update(ctx.script, fn _ -> results end)
  defp advance(ctx, ms), do: Agent.update(ctx.clock, &(&1 + ms))
  defp grant(token, expires_in), do: {:ok, %{token: token, expires_in: expires_in}}
  defp failure(kind), do: {:error, Error.new(kind, :service_token, "the issuer said no")}

  describe "caching" do
    test "a second call is served from the cache, with no second request", ctx do
      script(ctx, [grant("tok-a", 3_600)])

      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}
      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}

      assert_received {:requested, _pid}
      refute_received {:requested, _pid}
    end

    test "is good until expires_in minus 60 seconds, and refetches after", ctx do
      script(ctx, [grant("tok-a", 100), grant("tok-b", 100)])

      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}
      assert_received {:requested, _pid}

      # 100s lifetime, 60s skew: cached for 40s.
      advance(ctx, 39_999)
      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}
      refute_received {:requested, _pid}

      advance(ctx, 1)
      assert ServiceToken.fetch(@cache) == {:ok, "tok-b"}
      assert_received {:requested, _pid}
    end

    test "a token with 60 seconds or less to live is never served from the cache", ctx do
      script(ctx, [grant("tok-a", 60), grant("tok-b", 60)])

      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}
      assert ServiceToken.fetch(@cache) == {:ok, "tok-b"}
    end

    test "a failed fetch is not cached", ctx do
      script(ctx, [failure(:unavailable), grant("tok-a", 3_600)])

      assert {:error, %Error{kind: :unavailable}} = ServiceToken.fetch(@cache)
      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}

      assert_received {:requested, _pid}
      assert_received {:requested, _pid}
    end

    test "a failed fetch after expiry does not resurrect the expired token", ctx do
      script(ctx, [grant("tok-a", 100), failure(:unavailable)])

      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}
      advance(ctx, 40_000)

      assert {:error, %Error{kind: :unavailable}} = ServiceToken.fetch(@cache)
    end

    for {label, result} <- [
          {"no token", {:ok, %{token: "", expires_in: 3_600}}},
          {"a non-binary token", {:ok, %{token: 42, expires_in: 3_600}}},
          {"a zero lifetime", {:ok, %{token: "tok", expires_in: 0}}},
          {"a non-integer lifetime", {:ok, %{token: "tok", expires_in: "3600"}}},
          {"something that is not a grant", :nonsense}
        ] do
      test "a driver answering #{label} is :unavailable and not cached", ctx do
        script(ctx, [unquote(Macro.escape(result)), grant("tok-a", 3_600)])

        assert {:error, %Error{kind: :unavailable}} = ServiceToken.fetch(@cache)
        assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}
      end
    end

    test "errors keep the driver's kind and boundary", ctx do
      script(ctx, [failure(:auth_expired)])

      assert {:error, %Error{kind: :auth_expired, boundary: :service_token}} =
               ServiceToken.fetch(@cache)
    end
  end

  describe "concurrent callers" do
    test "share one fetch", ctx do
      script(ctx, [:block])

      first = Task.async(fn -> ServiceToken.fetch(@cache) end)
      assert_receive {:requested, fetcher}

      second = Task.async(fn -> ServiceToken.fetch(@cache) end)
      wait_for_waiters(2)

      send(fetcher, {:release, grant("tok-a", 3_600)})

      assert Task.await(first) == {:ok, "tok-a"}
      assert Task.await(second) == {:ok, "tok-a"}
      refute_received {:requested, _pid}
    end

    test "all receive the error when the shared fetch fails, and the next call tries again",
         ctx do
      script(ctx, [:block, grant("tok-a", 3_600)])

      first = Task.async(fn -> ServiceToken.fetch(@cache) end)
      assert_receive {:requested, fetcher}
      second = Task.async(fn -> ServiceToken.fetch(@cache) end)
      wait_for_waiters(2)

      send(fetcher, {:release, failure(:unavailable)})

      assert {:error, %Error{kind: :unavailable}} = Task.await(first)
      assert {:error, %Error{kind: :unavailable}} = Task.await(second)
      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}
    end

    # Each `:sys.get_state/1` is a round trip through the cache, so this spins
    # until the second caller's message has been handled, without sleeping.
    defp wait_for_waiters(count, attempts \\ 10_000) do
      case :sys.get_state(@cache) do
        %{inflight: %{waiters: waiters}} when length(waiters) == count ->
          :ok

        _not_yet when attempts > 0 ->
          wait_for_waiters(count, attempts - 1)

        _never ->
          flunk("the second caller never reached the cache")
      end
    end
  end

  describe "invalidate/2" do
    test "drops the cached token when it is the one that was rejected", ctx do
      script(ctx, [grant("tok-a", 3_600), grant("tok-b", 3_600)])

      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}
      ServiceToken.invalidate(@cache, "tok-a")

      assert ServiceToken.fetch(@cache) == {:ok, "tok-b"}
    end

    test "leaves a newer token alone — two 401s on one old token drop only the old", ctx do
      script(ctx, [grant("tok-a", 3_600), grant("tok-b", 3_600)])

      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}
      ServiceToken.invalidate(@cache, "tok-a")
      assert ServiceToken.fetch(@cache) == {:ok, "tok-b"}

      # A second caller that was also rejected on tok-a reports it late.
      ServiceToken.invalidate(@cache, "tok-a")

      assert ServiceToken.fetch(@cache) == {:ok, "tok-b"}
      assert_received {:requested, _pid}
      assert_received {:requested, _pid}
      refute_received {:requested, _pid}
    end

    test "is a no-op with nothing cached" do
      assert ServiceToken.invalidate(@cache, "tok-a") == :ok
      assert is_map(:sys.get_state(@cache))
    end

    test "clear/1 drops the cache unconditionally", ctx do
      script(ctx, [grant("tok-a", 3_600), grant("tok-b", 3_600)])

      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}
      assert ServiceToken.clear(@cache) == :ok
      assert ServiceToken.fetch(@cache) == {:ok, "tok-b"}
    end
  end

  describe "a driver that crashes" do
    test "is :unavailable for the caller, and the cache survives to serve the next call", ctx do
      script(ctx, [:raise, grant("tok-a", 3_600)])
      cache = Process.whereis(@cache)

      log =
        capture_log(fn ->
          assert {:error, %Error{kind: :unavailable}} = ServiceToken.fetch(@cache)
        end)

      assert log =~ "the issuer blew up"
      assert Process.whereis(@cache) == cache
      assert ServiceToken.fetch(@cache) == {:ok, "tok-a"}
    end
  end

  describe "fetch/1 when the cache is not running" do
    test "is :unavailable rather than an exit in the caller" do
      assert {:error, %Error{kind: :unavailable, boundary: :service_token}} =
               ServiceToken.fetch(:no_such_cache)
    end
  end

  describe "boundary/0" do
    test "is registered with Nucleus.Backend" do
      assert ServiceToken.boundary() == :service_token
      assert :service_token in Nucleus.Backend.boundaries()
    end
  end
end
