defmodule NucleusWeb.DataExportLive.States do
  @moduledoc """
  Shared non-content function components for `NucleusWeb.DataExportLive` —
  the enablement gate (`DEX-A01`) plus every `Nucleus.Backend.Error.kinds/0`
  value the configuration load can surface (`DEX-A13` and friends), mirroring
  `NucleusWeb.ApplicationsLive.States`/`NucleusWeb.M2MClientsLive.States`
  exactly, including the "mirror whatever landed for `:auth_expired`, don't
  invent a second pattern" rule.

  | Outcome | `:status` | DOM id |
  |---|---|---|
  | `kind: :not_found` | `:not_enabled` | `#data-export-not-enabled` |
  | `kind: :not_configured` | `:misconfigured` | `#data-export-misconfigured` |
  | `kind: :auth_expired` | `:auth_expired` | `#data-export-auth-expired` |
  | anything else (`:already_exists`, `:conflict`, `:invalid` — none of
    which `Nucleus.NomadVars.list/1` has reason to return today) |
    `:unavailable` | `#data-export-unavailable` |

  `:not_enabled` is its own state, distinct from every other kind below — it
  means the tenant genuinely has no Data Export configuration to show, not
  that a load failed. It carries no retry affordance, unlike `:unavailable`:
  retrying a call that will keep 404ing is not a transient-failure recovery,
  it is noise.
  """

  use NucleusWeb, :html

  @doc """
  Data Export has never been enabled for this tenant — `read/0`'s
  `:not_found` (`DEX-A01`). Not a transient failure, so no retry affordance.
  """
  attr :id, :string, default: "data-export-not-enabled"

  def not_enabled(assigns) do
    ~H"""
    <.empty_state
      id={@id}
      icon="hero-no-symbol"
      message="Data Export is not enabled for this tenant."
    />
    """
  end

  @doc """
  The `:nomad_vars` boundary has no usable configuration — an operations
  problem, not something the user did wrong.
  """
  attr :id, :string, default: "data-export-misconfigured"

  def misconfigured(assigns) do
    ~H"""
    <.empty_state
      id={@id}
      icon="hero-shield-exclamation"
      message="Data Export isn't configured yet. This is an operations issue, not something you can fix here."
    />
    """
  end

  @doc """
  Nomad (or the local backend standing in for it) can't be reached right
  now — carries a retry affordance, unlike the other states here (`DEX-A13`).
  """
  attr :id, :string, default: "data-export-unavailable"

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
  Nucleus's own credentials for the backend expired. Mirrors
  `NucleusWeb.ApplicationsLive.States.auth_expired/1` (in turn mirroring
  `NucleusWeb.M2MClientsLive.States`/`SEC-A18`/`SEC-S7`), rather than
  inventing a second pattern.
  """
  attr :id, :string, default: "data-export-auth-expired"

  def auth_expired(assigns) do
    ~H"""
    <.empty_state
      id={@id}
      icon="hero-lock-closed"
      message="Data Export can't be reached right now."
    />
    """
  end
end
