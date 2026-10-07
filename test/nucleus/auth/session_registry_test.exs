defmodule Nucleus.Auth.SessionRegistryTest do
  use Nucleus.AuditCase, async: true

  alias Nucleus.Auth.{Session, SessionRegistry}

  # Each test gets its own registry, named uniquely, with millisecond-scale
  # limits so the timers can really fire. `on_expire` reports to the test
  # process: the registry runs it in a supervised task, which is not the
  # process the audit sink is registered for.
  setup do
    test = self()
    name = :"registry_#{System.unique_integer([:positive])}"

    start_registry = fn opts ->
      start_supervised!(
        {SessionRegistry,
         Keyword.merge(
           [
             name: name,
             idle_ms: 10_000,
             max_age_ms: 60_000,
             on_expire: fn record, reason -> send(test, {:expired, record.id, reason}) end
           ],
           opts
         )}
      )
    end

    {:ok, name: name, start: start_registry}
  end

  defp attrs(overrides \\ %{}) do
    now = System.system_time(:millisecond)

    Map.merge(
      %{
        id: "s-#{System.unique_integer([:positive])}",
        user: "ada@example.com",
        tenant: "acme",
        signed_in_at: now
      },
      overrides
    )
  end

  # Waits for the registry to have handled every message sent so far.
  defp sync(name), do: :sys.get_state(name)

  describe "status/2" do
    @describetag action: "AUTH-A05"

    test "is :unknown for a session the registry has never heard of", %{name: name, start: start} do
      start.([])
      assert SessionRegistry.status("nobody", name) == :unknown
    end

    test "is :active for a registered session", %{name: name, start: start} do
      start.([])
      a = attrs()
      :ok = SessionRegistry.register(a, name)

      assert SessionRegistry.status(a.id, name) == :active
    end

    test "reads as expired the moment a deadline passes, before any timer has recorded it",
         %{name: name, start: start} do
      start.([])
      now = System.system_time(:millisecond)
      a = attrs(%{signed_in_at: now - 20_000, last_active: now - 11_000})
      :ok = SessionRegistry.register(a, name)

      assert SessionRegistry.status(a.id, name) == {:expired, :idle}
    end

    test "is :unknown rather than raising when the registry is not running" do
      assert SessionRegistry.status("x", :no_such_registry) == :unknown
    end
  end

  describe "idle timeout" do
    @describetag action: "AUTH-A08"

    test "ends a session that sees no activity, once", %{name: name, start: start} do
      start.(idle_ms: 60)
      a = attrs()
      :ok = SessionRegistry.register(a, name)

      id = a.id
      assert_receive {:expired, ^id, :idle}, 1_000
      refute_receive {:expired, ^id, _}, 150
      assert SessionRegistry.status(id, name) == {:expired, :idle}
    end

    test "is pushed back by activity", %{name: name, start: start} do
      start.(idle_ms: 150)
      now = System.system_time(:millisecond)
      # Already 100ms into a 150ms idle window: the timer fires in ~50ms...
      a = attrs(%{signed_in_at: now - 1_000, last_active: now - 100})
      :ok = SessionRegistry.register(a, name)
      # ...but this touch grants a fresh 150ms.
      SessionRegistry.touch(a.id, name)
      sync(name)

      id = a.id
      refute_receive {:expired, ^id, _}, 100
      assert_receive {:expired, ^id, :idle}, 1_000
    end

    test "ignores activity on a session that has already ended", %{name: name, start: start} do
      start.([])
      a = attrs()
      :ok = SessionRegistry.register(a, name)
      {:ok, _} = SessionRegistry.expire(a, :idle, name)

      SessionRegistry.touch(a.id, name)
      sync(name)

      assert SessionRegistry.status(a.id, name) == {:expired, :idle}
    end

    test "does not let activity resurrect a session that is already past its deadline",
         %{name: name, start: start} do
      start.([])
      now = System.system_time(:millisecond)
      a = attrs(%{signed_in_at: now - 20_000, last_active: now - 11_000})
      :ok = SessionRegistry.register(a, name)

      SessionRegistry.touch(a.id, name)
      sync(name)

      assert SessionRegistry.status(a.id, name) == {:expired, :idle}
    end
  end

  describe "max age" do
    @describetag action: "AUTH-A08"

    test "ends a session however active it is", %{name: name, start: start} do
      start.(max_age_ms: 80)
      a = attrs()
      :ok = SessionRegistry.register(a, name)
      SessionRegistry.touch(a.id, name)

      id = a.id
      assert_receive {:expired, ^id, :max_age}, 1_000
    end
  end

  describe "expire/3" do
    @describetag action: "AUTH-A08"

    test "is won by exactly one caller", %{name: name, start: start} do
      start.([])
      a = attrs()
      :ok = SessionRegistry.register(a, name)

      assert {:ok, record} = SessionRegistry.expire(a, :idle, name)
      assert record.id == a.id
      assert record.status == {:expired, :idle}
      assert SessionRegistry.expire(a, :idle, name) == :already
      assert SessionRegistry.expire(a, :max_age, name) == :already
      assert SessionRegistry.status(a.id, name) == {:expired, :idle}
    end

    test "cancels the session's timer, so the announcement is not made twice",
         %{name: name, start: start} do
      start.(idle_ms: 60)
      a = attrs()
      :ok = SessionRegistry.register(a, name)
      {:ok, _} = SessionRegistry.expire(a, :idle, name)

      id = a.id
      refute_receive {:expired, ^id, _}, 200
    end

    test "records a session the registry never held, so a replayed stale cookie is announced once",
         %{name: name, start: start} do
      start.([])
      a = attrs()

      assert {:ok, _} = SessionRegistry.expire(a, :idle, name)
      assert SessionRegistry.expire(a, :idle, name) == :already
      assert SessionRegistry.status(a.id, name) == {:expired, :idle}
    end

    test "a sign-out is an expiry with reason :user", %{name: name, start: start} do
      start.([])
      a = attrs()
      :ok = SessionRegistry.register(a, name)

      assert {:ok, _} = SessionRegistry.expire(a, :user, name)
      assert SessionRegistry.status(a.id, name) == {:expired, :user}
    end
  end

  describe "terminate_session/2" do
    @describetag action: "AUTH-A05"

    test "marks a held session terminated", %{name: name, start: start} do
      start.([])
      a = attrs()
      :ok = SessionRegistry.register(a, name)

      assert SessionRegistry.terminate_session(a.id, name) == :ok
      assert SessionRegistry.status(a.id, name) == :terminated
    end

    test "reports :unknown for a session it does not hold", %{name: name, start: start} do
      start.([])
      assert SessionRegistry.terminate_session("nobody", name) == :unknown
    end
  end

  describe "announce_expiry/2" do
    @describetag action: "AUTH-A09"

    test "emits sign_out with the reason and disconnects every tab on the session" do
      record = %{id: "abc", user: "ada@example.com", tenant: "acme"}
      NucleusWeb.Endpoint.subscribe(Session.live_socket_id("abc"))

      assert SessionRegistry.announce_expiry(record, :idle) == :ok

      assert_audit_event(:sign_out, user: "ada@example.com", tenant: "acme", reason: "idle")
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect", topic: "auth_sessions:abc"}
    end
  end

  describe "pruning" do
    test "forgets sessions once their max age has passed", %{name: name, start: start} do
      pid = start.(max_age_ms: 50)
      now = System.system_time(:millisecond)
      old = attrs(%{signed_in_at: now - 1_000})
      :ok = SessionRegistry.register(old, name)
      {:ok, _} = SessionRegistry.expire(old, :idle, name)

      send(pid, :prune)
      sync(name)

      assert SessionRegistry.status(old.id, name) == :unknown
    end
  end
end
