defmodule NucleusWeb.SecretsLive do
  @moduledoc """
  Placeholder so `/environments/:environment/secrets` compiles and
  `Layouts.app`'s sidebar (`NAV-A04`) has a real, navigable destination —
  EN-7's plan explicitly allows this ("this ticket may add a minimal
  placeholder module so the route compiles, clearly marked").

  **This is not the Secrets feature.** `SEC-S1` (environment resolution and
  the fail-closed validation ladder) and `SEC-S2` (the actual secrets list)
  replace this module's body entirely — nothing here should be extended.
  Renders an explicit "not implemented" state via `<.empty_state>`, never a
  blank page.

  `current_scope` and `environments` come from the `:authenticated`
  `live_session`'s `on_mount` hooks (`NucleusWeb.ScopeHook`,
  `NucleusWeb.EnvironmentsHook`) in `lib/nucleus_web/router.ex` — this
  module does not assign either itself.
  """

  use NucleusWeb, :live_view

  @impl Phoenix.LiveView
  def mount(%{"environment" => environment}, _session, socket) do
    {:ok, assign(socket, :environment, environment)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} environments={@environments}>
      <.empty_state
        id="secrets-not-implemented"
        icon="hero-wrench-screwdriver"
        message={"Secrets for \"#{@environment}\" is not implemented yet — see SEC-S1/SEC-S2."}
      />
    </Layouts.app>
    """
  end
end
