defmodule NucleusWeb.M2MClientsLive.States do
  @moduledoc """
  Shared error-state function components for `NucleusWeb.M2MClientsLive.Index`
  and (eventually) `.Show` — issue #35's Decision 7 calls these out
  specifically: two modules can't share markup by accident, so this has to be
  a real component, not a copy-paste starting point.

  `Nucleus.M2M.list/1` can only ever gate through `Nucleus.M2M.DenyList`
  (`:not_configured`) or `Nucleus.M2M.Clients.list_clients/0`
  (`:unavailable`, `:auth_expired`, or — theoretically — one of the
  remaining `Nucleus.Backend.Error.kinds/0`), so `Index` collapses every kind
  to one of the three states here, mirroring `NucleusWeb.SecretsLive`'s
  exhaustive `case` (`docs/adr/0010`) so no kind is left unhandled and no
  branch crashes the LiveView.

  `Index` uses all three; `Show` (M2M-S3, #36) imports this module and adds
  its own `#m2m-client-invalid-id`/`#m2m-client-not-found` — not implemented
  here, since this ticket's `Show` is a stub with no gate to fail.
  """

  use NucleusWeb, :html

  @doc """
  `M2M_DENY_SUFFIXES` unset, or otherwise unreadable — an operations
  problem, not something the user did wrong.
  """
  attr :id, :string, default: "m2m-clients-misconfigured"

  def misconfigured(assigns) do
    ~H"""
    <.empty_state
      id={@id}
      icon="hero-shield-exclamation"
      message="M2M Clients isn't configured yet. This is an operations issue, not something you can fix here."
    />
    """
  end

  @doc """
  Cognito (or the local backend standing in for it) can't be reached right
  now — carries a retry affordance, unlike the other two states.
  """
  attr :id, :string, default: "m2m-clients-unavailable"

  def unavailable(assigns) do
    ~H"""
    <.empty_state
      id={@id}
      icon="hero-exclamation-triangle"
      message="Can't reach the M2M client directory right now. Try again shortly."
    >
      <:action>
        <.button phx-click="retry">Retry</.button>
      </:action>
    </.empty_state>
    """
  end

  @doc """
  Nucleus's own credentials for the backend expired. Placeholder copy —
  `SEC-A18`'s slice (`SEC-S7`) owns the real copy and retry semantics; this
  mirrors whatever that lands rather than inventing a second pattern.
  """
  attr :id, :string, default: "m2m-clients-auth-expired"

  def auth_expired(assigns) do
    ~H"""
    <.empty_state
      id={@id}
      icon="hero-lock-closed"
      message="M2M clients can't be reached right now."
    />
    """
  end
end
