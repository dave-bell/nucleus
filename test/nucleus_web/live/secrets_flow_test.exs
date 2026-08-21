defmodule NucleusWeb.SecretsFlowTest do
  @moduledoc """
  Demonstrates `PhoenixTest` (EN-8's acceptance criteria: "added and
  demonstrated by at least one flow test") against the one real flow that
  exists today — `NucleusWeb.SecretsLive` now resolves the environment
  through `Nucleus.Environments` (`SEC-S1`), but renders no secrets UI of
  its own yet (`SEC-S2` builds the list). The shell's environment-picker
  navigation is real (EN-7) and worth exercising end to end: load one
  environment's secrets page, follow a sidebar link to another environment's
  detail view (`ENV-S1` repointed the sidebar there), then on to its secrets
  via "Manage Secrets" (`ENV-A04`).

  Unlike `Phoenix.LiveViewTest`'s `live/2`, `PhoenixTest.visit/2` returns a
  session that also seamlessly follows a *static* page — nothing here
  happens to cross that boundary today, but it is why this test, not
  `NucleusWeb.LiveCase`'s `live_secrets/2`, is the right tool once a flow
  spans both live and static pages (e.g. after EN-6's real sign-in lands).

  `async: false`: `visit/2` goes through the real `:assign_scope` pipeline
  (`NucleusWeb.Plugs.AssignScope`), which reads `config :nucleus,
  Nucleus.Scope` — the same global config
  `NucleusWeb.Plugs.AssignScopeTest`'s `"AUTH_ENABLED=true raises"` test
  deliberately mutates. `async: true` here previously raced that mutation
  and surfaced `Nucleus.Scope.Provider.Cognito`'s intentional raise on an
  otherwise-passing run — the same hazard `Nucleus.BackendCase`'s moduledoc
  documents for `Nucleus.Backend.Seed`, one boundary over.
  """

  use NucleusWeb.ConnCase, async: false

  import PhoenixTest

  @tag :unit
  test "an ops user follows the sidebar to an environment's detail, then to its secrets", %{
    conn: conn
  } do
    conn
    |> visit(~p"/environments/prod/secrets")
    |> assert_has("#tenant-identifier")
    |> assert_has("#environments-list", text: "Staging", timeout: 100)
    |> click_link("Staging")
    |> assert_path(~p"/environments/staging")
    |> assert_has("#environment-detail")
    |> click_link("Manage Secrets")
    |> assert_path(~p"/environments/staging/secrets")
    |> assert_has("#tenant-identifier")
  end

  @tag :unit
  test "an archived environment's secrets page is reachable directly but not linked from the sidebar",
       %{conn: conn} do
    conn
    |> visit(~p"/environments/legacy-qa/secrets")
    |> assert_has("#tenant-identifier")
    # Wait for the async environments list to actually resolve (proven by a
    # real, non-archived entry appearing) before asserting an absence —
    # otherwise this would vacuously pass while #environments-list hasn't
    # rendered yet at all (still showing #environments-loading), the same
    # hazard shell_test.exs's `render_async/1` calls guard against.
    |> assert_has("#environments-list", text: "Staging", timeout: 100)
    |> refute_has("#environments-list", text: "Legacy QA")
  end
end
