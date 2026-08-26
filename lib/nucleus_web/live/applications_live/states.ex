defmodule NucleusWeb.ApplicationsLive.States do
  @moduledoc """
  Shared error-state function components for `NucleusWeb.ApplicationsLive`
  (`APP-A07`) — mirrors `NucleusWeb.M2MClientsLive.States` exactly (issue
  #58's plan names it as the pattern to follow), including the "mirror
  whatever landed for `:auth_expired`, don't invent a second pattern" rule.

  `Nucleus.NomadJobs.list/1` can return any `Nucleus.Backend.Error.kinds/0`
  value — `NucleusWeb.ApplicationsLive` collapses every kind to one of the
  three states here, so no kind is left unhandled and no branch crashes the
  LiveView:

  | Outcome | `:status` | DOM id |
  |---|---|---|
  | `kind: :not_configured` | `:misconfigured` | `#applications-misconfigured` |
  | `kind: :unavailable` | `:unavailable` | `#applications-unavailable` |
  | `kind: :auth_expired` | `:auth_expired` | `#applications-auth-expired` |
  | anything else (`:not_found`, `:already_exists`, `:invalid` — none of
    which `list/1` has reason to return today) | `:unavailable` | `#applications-unavailable` |
  """

  use NucleusWeb, :html

  @doc """
  The `:nomad_jobs` boundary has no usable configuration — an operations
  problem, not something the user did wrong.
  """
  attr :id, :string, default: "applications-misconfigured"

  def misconfigured(assigns) do
    ~H"""
    <.empty_state
      id={@id}
      icon="hero-shield-exclamation"
      message="Applications isn't configured yet. This is an operations issue, not something you can fix here."
    />
    """
  end

  @doc """
  Nomad (or the local backend standing in for it) can't be reached right
  now — carries a retry affordance, unlike the other two states (`APP-A07`).
  """
  attr :id, :string, default: "applications-unavailable"

  def unavailable(assigns) do
    ~H"""
    <.empty_state
      id={@id}
      icon="hero-exclamation-triangle"
      message="Can't reach Nomad right now. Try again shortly."
    >
      <:action>
        <.button phx-click="retry">Retry</.button>
      </:action>
    </.empty_state>
    """
  end

  @doc """
  Nucleus's own credentials for the backend expired. Mirrors whatever
  `NucleusWeb.M2MClientsLive.States.auth_expired/1` (in turn mirroring
  `SEC-A18`/`SEC-S7`) landed for this kind, rather than inventing a second
  pattern.
  """
  attr :id, :string, default: "applications-auth-expired"

  def auth_expired(assigns) do
    ~H"""
    <.empty_state
      id={@id}
      icon="hero-lock-closed"
      message="Applications can't be reached right now."
    />
    """
  end
end
