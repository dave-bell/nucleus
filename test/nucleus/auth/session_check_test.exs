defmodule Nucleus.Auth.SessionCheckTest do
  use Nucleus.AuditCase, async: true

  alias Nucleus.Auth.{Config, Session, SessionCheck, SessionRegistry}

  setup do
    name = :"check_registry_#{System.unique_integer([:positive])}"
    start_supervised!({SessionRegistry, name: name, on_expire: fn _record, _reason -> :ok end})
    {:ok, registry: name, now: System.system_time(:second)}
  end

  defp session(now, overrides \\ []) do
    struct!(
      %Session{
        id: "sid-#{System.unique_integer([:positive])}",
        email: "ada@example.com",
        username: "ada",
        signed_in_at: now,
        last_active: now
      },
      overrides
    )
  end

  defp validate(auth, registry, now) do
    SessionCheck.validate(%{"auth" => auth}, registry: registry, now: now)
  end

  describe "no session" do
    @describetag action: "AUTH-A06"

    test "an empty session is :no_session and is not audited", %{registry: registry} do
      assert SessionCheck.validate(%{}, registry: registry) == {:error, :no_session}
      assert audit_events() == []
    end

    test "an auth entry of the wrong shape (a tampered or foreign cookie) is :no_session",
         %{registry: registry} do
      assert SessionCheck.validate(%{"auth" => %{"id" => "x"}}, registry: registry) ==
               {:error, :no_session}

      assert SessionCheck.validate(%{"auth" => "garbage"}, registry: registry) ==
               {:error, :no_session}

      assert audit_events() == []
    end
  end

  describe "a valid session" do
    @describetag action: "AUTH-A05"

    test "unknown to the registry but fresh in the cookie is accepted and re-registered (restart recovery)",
         %{registry: registry, now: now} do
      auth = session(now)

      assert {:ok, %Session{}} = validate(auth, registry, now)
      assert SessionRegistry.status(auth.id, registry) == :active
    end

    test "advances last_active and counts as activity", %{registry: registry, now: now} do
      auth = session(now - 100, last_active: now - 100)
      :ok = SessionRegistry.register(SessionCheck.attrs(auth), registry)

      assert {:ok, %Session{last_active: ^now}} = validate(auth, registry, now)
    end

    test "rejects recovery when logout wins after the unknown-status read",
         %{registry: registry, now: now} do
      auth = session(now)
      pid = Process.whereis(registry)
      supervisor = start_supervised!(Task.Supervisor)
      :sys.suspend(pid)

      try do
        logout_ref = make_ref()

        send(
          pid,
          {:"$gen_call", {self(), logout_ref}, {:expire, SessionCheck.attrs(auth), :user}}
        )

        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            receive do
              :validate -> validate(auth, registry, now)
            end
          end)

        :erlang.trace(task.pid, true, [:send])
        send(task.pid, :validate)
        task_pid = task.pid

        assert_receive {:trace, ^task_pid, :send, {:"$gen_call", _from, {:register, _attrs}},
                        ^pid}

        :sys.resume(pid)
        assert_receive {^logout_ref, {:ok, _record}}
        assert Task.await(task) == {:error, {:expired, :user}}
        assert SessionRegistry.status(auth.id, registry) == {:expired, :user}
        assert audit_events() == []
      after
        :sys.resume(pid)
      end
    end
  end

  describe "max age" do
    @describetag action: "AUTH-A08"

    test "ends a session past SESSION_MAX_AGE, however recently it was active",
         %{registry: registry, now: now} do
      auth = session(now, signed_in_at: now - Config.max_age() - 1)

      assert validate(auth, registry, now) == {:error, {:expired, :max_age}}
      assert_audit_event(:sign_out, user: "ada@example.com", reason: "max_age")
    end

    test "is announced once however many requests discover it", %{registry: registry, now: now} do
      auth = session(now, signed_in_at: now - Config.max_age() - 1)

      assert validate(auth, registry, now) == {:error, {:expired, :max_age}}
      assert validate(auth, registry, now) == {:error, {:expired, :max_age}}

      assert [_one] = Enum.filter(audit_events(), &(&1.event == :sign_out))
    end

    test "stale-cookie replays after repeated pruning do not announce expiry again",
         %{registry: registry, now: now} do
      auth = session(now, signed_in_at: now - Config.max_age() - 1)
      NucleusWeb.Endpoint.subscribe(Session.live_socket_id(auth.id))

      assert validate(auth, registry, now) == {:error, {:expired, :max_age}}
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      for _ <- 1..2 do
        send(registry, :prune)
        :sys.get_state(registry)
        assert validate(auth, registry, now) == {:error, {:expired, :max_age}}
      end

      assert [%{reason: "max_age"}] = Enum.filter(audit_events(), &(&1.event == :sign_out))
      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end

  describe "idle timeout" do
    @describetag action: "AUTH-A08"

    test "ends a session the registry does not know whose cookie went idle (after a restart)",
         %{registry: registry, now: now} do
      auth = session(now, last_active: now - Config.idle_timeout() - 1)

      assert validate(auth, registry, now) == {:error, {:expired, :idle}}
      assert_audit_event(:sign_out, reason: "idle")
      assert SessionRegistry.status(auth.id, registry) == {:expired, :idle}
    end

    test "ends a session the registry knows has gone idle, and announces it once",
         %{registry: registry, now: now} do
      auth = session(now)
      past = (now - Config.idle_timeout() - 1) * 1000
      :ok = SessionRegistry.register(%{SessionCheck.attrs(auth) | last_active: past}, registry)

      assert validate(auth, registry, now) == {:error, {:expired, :idle}}
      assert validate(auth, registry, now) == {:error, {:expired, :idle}}

      assert [%{reason: "idle"}] = Enum.filter(audit_events(), &(&1.event == :sign_out))
    end

    test "trusts the registry over a stale cookie when the registry saw later activity",
         %{registry: registry, now: now} do
      # The cookie says idle (no HTTP request for an hour), but the user has
      # been clicking around in a LiveView, which only the registry heard.
      auth = session(now - 4000, last_active: now - 4000)

      :ok =
        SessionRegistry.register(%{SessionCheck.attrs(auth) | last_active: now * 1000}, registry)

      assert {:ok, _} = validate(auth, registry, now)
      assert audit_events() == []
    end
  end

  describe "ended sessions" do
    @describetag action: "AUTH-A05"

    test "a signed-out session is rejected silently, since logout already announced it",
         %{registry: registry, now: now} do
      auth = session(now)
      :ok = SessionRegistry.register(SessionCheck.attrs(auth), registry)
      {:ok, _} = SessionRegistry.expire(SessionCheck.attrs(auth), :user, registry)

      assert validate(auth, registry, now) == {:error, {:expired, :user}}
      assert audit_events() == []
    end

    test "a terminated session is rejected", %{registry: registry, now: now} do
      auth = session(now)
      :ok = SessionRegistry.register(SessionCheck.attrs(auth), registry)
      :ok = SessionRegistry.terminate_session(auth.id, registry)

      assert validate(auth, registry, now) == {:error, :terminated}
    end
  end
end
