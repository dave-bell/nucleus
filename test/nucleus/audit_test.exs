defmodule Nucleus.AuditTest do
  # Mutates :nucleus, Nucleus.Audit application config in the sink-failure
  # test below, which is global.
  use ExUnit.Case, async: false

  alias Nucleus.Audit
  alias Nucleus.Audit.Sink

  doctest Nucleus.Audit.Event

  setup do
    Sink.Test.register(self())
    :ok
  end

  defp assert_audit_record do
    assert_receive {:audit, binary}, 100
    refute_receive {:audit, _other}, 0
    Jason.decode!(binary)
  end

  describe "emit/2 with valid fields" do
    @tag :unit
    test "returns :ok and produces exactly one record" do
      assert Audit.emit(:secret_viewed, tenant: "acme", resource: "acme/prod/api-key") == :ok

      record = assert_audit_record()

      assert record["event"] == "secret_viewed"
      assert record["tenant"] == "acme"
      assert record["resource"] == "acme/prod/api-key"
    end
  end

  describe "emit/2 validation" do
    @tag :unit
    test "an unknown event atom raises" do
      # Built at runtime: the compiler's type checker rejects the literal,
      # since it knows :secret_view is outside the declared event union.
      unknown = String.to_atom("secret_view")

      error = assert_raise ArgumentError, fn -> Audit.emit(unknown, tenant: "acme") end

      assert error.message =~ "unknown audit event :secret_view"
    end

    @tag :unit
    test ":secret_viewed without resource raises" do
      error = assert_raise ArgumentError, fn -> Audit.emit(:secret_viewed, tenant: "acme") end

      assert error.message =~ "missing required field(s)"
      assert error.message =~ ":resource"
    end

    @tag :unit
    test "an unknown field key raises" do
      error =
        assert_raise ArgumentError, fn ->
          Audit.emit(:secret_viewed, tenant: "acme", resource: "x", bogus: 1)
        end

      assert error.message =~ "unknown field :bogus"
    end

    @tag :unit
    @tag action: "AUD-A02"
    test "a value: key raises — the explicit AUD-A02 guard" do
      error =
        assert_raise ArgumentError, fn ->
          Audit.emit(:secret_viewed, tenant: "acme", resource: "x", value: "super-secret")
        end

      assert error.message =~ "unknown field :value"
    end

    @tag :unit
    @tag action: "AUD-A01"
    test "a caller-supplied timestamp is rejected; the emitted timestamp is UTC and current" do
      error =
        assert_raise ArgumentError, fn ->
          Audit.emit(:secret_viewed,
            tenant: "acme",
            resource: "x",
            timestamp: ~U[2000-01-01 00:00:00Z]
          )
        end

      assert error.message =~ "unknown field :timestamp"

      before = DateTime.utc_now()
      assert Audit.emit(:secret_viewed, tenant: "acme", resource: "x") == :ok
      afterward = DateTime.utc_now()

      record = assert_audit_record()
      {:ok, timestamp, 0} = DateTime.from_iso8601(record["timestamp"])

      assert DateTime.compare(timestamp, before) != :lt
      assert DateTime.compare(timestamp, afterward) != :gt
    end

    @tag :unit
    test "absent user becomes \"anonymous\"" do
      assert Audit.emit(:secret_viewed, tenant: "acme", resource: "x") == :ok

      assert assert_audit_record()["user"] == "anonymous"
    end

    @tag :unit
    test "an unknown field key raises even when nested under :details" do
      # secret_created's spec doesn't allow a top-level :details key at all,
      # so this only proves the top-level check, not the per-event details
      # allowlist below.
      error =
        assert_raise ArgumentError, fn ->
          Audit.emit(:secret_created,
            tenant: "acme",
            resource: "x",
            details: %{value: "super-secret"}
          )
        end

      assert error.message =~ "unknown field :details for audit event :secret_created"
    end

    @tag :unit
    test "an unknown key inside details raises — the per-event details allowlist" do
      # nomad_var_updated does support :details, so this exercises the inner
      # key allowlist itself, not the outer :details rejection above.
      error =
        assert_raise ArgumentError, fn ->
          Audit.emit(:nomad_var_updated,
            tenant: "acme",
            details: %{path: "/api/secrets", key: "DATABASE_URL", value: "super-secret"}
          )
        end

      assert error.message =~ "unknown detail :value for audit event :nomad_var_updated"
    end

    @tag :unit
    test "a required detail key raises when missing" do
      error =
        assert_raise ArgumentError, fn ->
          Audit.emit(:nomad_var_updated, tenant: "acme", details: %{key: "DATABASE_URL"})
        end

      assert error.message =~ "missing required field(s)"
      assert error.message =~ ":path"
    end
  end

  describe "emit/2 sink failure (AUD-A07)" do
    @tag :unit
    @tag action: "AUD-A07"
    test "a raising sink propagates rather than being swallowed" do
      original = Application.fetch_env!(:nucleus, Audit)
      Application.put_env(:nucleus, Audit, Keyword.put(original, :sink, Sink.Raising))
      on_exit(fn -> Application.put_env(:nucleus, Audit, original) end)

      assert_raise RuntimeError, "boom: the sink is down", fn ->
        Audit.emit(:secret_viewed, tenant: "acme", resource: "x")
      end
    end
  end

  describe "catalogue-drift guard" do
    @tag :unit
    @tag action: "AUD-A02"
    test "no event's catalogue allows a value-bearing field name" do
      value_bearing = ~w(value secret plaintext new_value password token)a

      for event <- Nucleus.Audit.Event.events() do
        spec = Nucleus.Audit.Event.spec(event)

        for field <- value_bearing do
          refute field in spec.allowed,
                 "#{event} allows top-level :#{field}"

          refute field in spec.details_allowed,
                 "#{event} allows details.#{field}"
        end
      end
    end
  end

  describe "AUD-A01 exhaustiveness — every catalogued event" do
    @tag :unit
    @tag action: "AUD-A01"
    test "every event's spec requires :tenant plus an identifying field" do
      for event <- Nucleus.Audit.Event.events() do
        spec = Nucleus.Audit.Event.spec(event)
        assert :tenant in spec.required, "#{event} does not require :tenant"

        identifying? =
          :resource in spec.required or
            Enum.any?(spec.details_required, &(&1 in [:path, :key, :client_name]))

        assert identifying?, "#{event} has no required identifying field"
      end
    end

    # The maintained call-site list AUD-A01 requires: every catalogued event
    # must actually be emitted somewhere, not merely specced. Each entry is
    # the {module, function, arity} that calls `Audit.emit/2` for that event.
    # `auth_failure` is the one named exception — AUD-S4, blocked on
    # authentication (docs/adr/0005-deferred-authentication.md). Adding a new
    # catalogued event with no entry here fails this test loudly, forcing a
    # decision instead of silently passing.
    @wired_call_sites %{
      nomad_vars_listed: {Nucleus.NomadVars, :list, 1},
      nomad_var_updated: {Nucleus.NomadVars, :update, 5},
      env_names_updated: {Nucleus.NomadVars, :update_env_names, 4},
      secret_created: {Nucleus.Secrets, :create, 4},
      secret_viewed: {Nucleus.Secrets, :reveal, 3},
      secret_updated: {Nucleus.Secrets, :update, 4},
      m2m_client_created: {Nucleus.M2M, :create, 4},
      m2m_client_viewed: {Nucleus.M2M, :view, 2},
      m2m_secret_rotated: {Nucleus.M2M, :rotate, 2}
    }
    @known_unwired [:auth_failure]

    @tag :unit
    @tag action: "AUD-A01"
    test "every catalogued event except auth_failure has a live call site" do
      catalogued = MapSet.new(Nucleus.Audit.Event.events())
      wired = MapSet.new(Map.keys(@wired_call_sites))
      unwired = MapSet.new(@known_unwired)

      assert MapSet.union(wired, unwired) == catalogued,
             "catalogue drift: every event must be either wired (in @wired_call_sites) " <>
               "or explicitly named unwired (in @known_unwired)"

      assert MapSet.disjoint?(wired, unwired),
             "an event cannot be both wired and named as a known exemption"

      for {event, {module, function, arity}} <- @wired_call_sites do
        Code.ensure_loaded!(module)

        assert function_exported?(module, function, arity),
               "#{event}'s claimed call site #{inspect(module)}.#{function}/#{arity} does not exist"
      end
    end
  end
end
