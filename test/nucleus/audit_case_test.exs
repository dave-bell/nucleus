defmodule Nucleus.AuditCaseTest do
  @moduledoc """
  Self-tests for `Nucleus.AuditCase`, including the AUD-A02 guard
  (`refute_audit_contains/1`) SEC-S4/S5/S6 each depend on — see EN-8 (issue
  #8). `refute_audit_contains/1` in particular must be proven able to fail,
  or it could silently pass forever.

  `Nucleus.Audit.Sink.Test.register/1` stores its pid in the *calling*
  process's dictionary, so this is `async: true` safe.
  """

  use Nucleus.AuditCase, async: true

  alias Nucleus.Audit

  @tag :unit
  test "assert_audit_event/2 passes when a matching event was emitted" do
    Audit.emit(:secret_viewed, tenant: "acme", resource: "/prod/API_KEY")

    assert_audit_event(:secret_viewed, tenant: "acme", resource: "/prod/API_KEY")
  end

  @tag :unit
  test "assert_audit_event/2 matches a subset of a details map" do
    Audit.emit(:m2m_client_created,
      tenant: "acme",
      details: %{client_name: "svc-billing", ticket_id: "TICKET-1"}
    )

    assert_audit_event(:m2m_client_created, details: %{client_name: "svc-billing"})
  end

  @tag :unit
  test "assert_audit_event/2 fails when no emitted event matches" do
    Audit.emit(:secret_viewed, tenant: "acme", resource: "/prod/API_KEY")

    assert_raise ExUnit.AssertionError, fn ->
      assert_audit_event(:secret_viewed, resource: "/prod/OTHER_KEY")
    end
  end

  @tag :unit
  test "assert_audit_event/2 fails when no event was emitted at all" do
    assert_raise ExUnit.AssertionError, fn ->
      assert_audit_event(:secret_viewed)
    end
  end

  @tag :unit
  test "assert_no_audit_event/1 passes when the named event was never emitted" do
    Audit.emit(:secret_viewed, tenant: "acme", resource: "/prod/API_KEY")

    assert_no_audit_event(:secret_updated)
  end

  @tag :unit
  test "assert_no_audit_event/1 fails when the named event was emitted" do
    Audit.emit(:secret_viewed, tenant: "acme", resource: "/prod/API_KEY")

    assert_raise ExUnit.AssertionError, fn ->
      assert_no_audit_event(:secret_viewed)
    end
  end

  @tag :unit
  test "refute_audit_contains/1 passes when the value appears in no emitted record" do
    Audit.emit(:secret_viewed, tenant: "acme", resource: "/prod/API_KEY")

    refute_audit_contains("s3cr3t-plaintext-value")
  end

  @tag :unit
  test "refute_audit_contains/1 fails when the value is present — proving the guard can fail" do
    Audit.emit(:auth_failure,
      tenant: "acme",
      reason: "expired",
      details: %{path: "/leaked/s3cr3t-plaintext-value"}
    )

    assert_raise ExUnit.AssertionError, fn ->
      refute_audit_contains("s3cr3t-plaintext-value")
    end
  end

  @tag :unit
  test "audit_events/0 returns every emitted record, in order" do
    Audit.emit(:secret_viewed, tenant: "acme", resource: "/prod/A")
    Audit.emit(:secret_viewed, tenant: "acme", resource: "/prod/B")

    assert [%{resource: "/prod/A"}, %{resource: "/prod/B"}] = audit_events()
  end

  @tag :unit
  test "audit_events/0 is stable across repeated calls within the same test" do
    Audit.emit(:secret_viewed, tenant: "acme", resource: "/prod/A")

    assert audit_events() == audit_events()
  end
end
