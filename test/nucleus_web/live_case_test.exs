defmodule NucleusWeb.LiveCaseTest do
  @moduledoc """
  Self-test for `NucleusWeb.LiveCase` — every SEC ticket's LiveView tests are
  expected to build on this case, so it must actually mount a real LiveView
  with `current_scope` assigned. See EN-8 (issue #8).

  Mutates `Nucleus.Backend.Seed`/fault env vars via the composed
  `Nucleus.BackendCase`, so `async: false`.
  """

  use NucleusWeb.LiveCase, async: false

  @tag :unit
  test "live_secrets/2 mounts NucleusWeb.SecretsLive with current_scope assigned", %{conn: conn} do
    {:ok, view, _html} = live_secrets(conn, "prod")

    assert has_element?(view, "#user-menu", "test-dev@example.com")
  end

  @tag :unit
  test "seed_secret (Nucleus.BackendCase) and assert_audit_event (Nucleus.AuditCase) both compose",
       %{conn: conn} do
    seed_secret("prod", "LIVE_CASE_TEST_KEY", "shh")

    Nucleus.Audit.emit(:secret_viewed, tenant: "acme", resource: "/prod/LIVE_CASE_TEST_KEY")

    {:ok, _view, _html} = live_secrets(conn, "prod")

    assert {:ok, secret} = Nucleus.Secrets.Store.get_secret("prod", "LIVE_CASE_TEST_KEY")
    assert secret.value == "shh"
    assert_audit_event(:secret_viewed, resource: "/prod/LIVE_CASE_TEST_KEY")
  end
end
