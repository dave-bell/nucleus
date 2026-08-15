defmodule NucleusWeb.SecretsLive do
  @moduledoc """
  The Secrets view for one environment — the gate every other Secrets action
  (`SEC-A01` onward) mounts through.

  Replaces the `SEC-S1`-marked placeholder wholesale (see ADR-0006 §"the
  disposable placeholder"), not incrementally.

  ## Validated in `handle_params/3`, not `mount/3`

  The environment name comes from the URL, and a `<.link patch={...}>` can
  change it without a remount — `handle_params/3` runs on every patch,
  `mount/3` does not. Putting the check in `mount/3` would let a user patch
  from a valid environment straight into an unvalidated one.

  ## Three distinct, mutually exclusive states

  `Nucleus.Environments.fetch/2` returns one of four outcomes, and each gets
  its own assign and its own DOM id — collapsing "not found" and
  "unavailable" into one rendering would misinform the user about a real
  outage (`SEC-A17`):

  | Outcome | `:environment_status` | DOM id |
  |---|---|---|
  | `{:ok, environment}` | `:ok` | (list rendering is `SEC-S2`) |
  | `kind: :invalid` | `:invalid` | `#secrets-invalid-environment` |
  | `kind: :not_found` | `:not_found` | `#secrets-environment-not-found` |
  | `kind: :unavailable` | `:unavailable` | `#secrets-validation-unavailable` |

  Every branch keeps the shell intact (`<Layouts.app>`, `#tenant-identifier`)
  so the user can navigate away — a crashed LiveView is not an acceptable
  rendering of any of these. No secrets UI (table, create button, reveal
  control) renders in any error state, and the raw environment name is never
  echoed unescaped — HEEx's default escaping is not defeated with `raw/1`.

  `current_scope` and `environments` come from the `:authenticated`
  `live_session`'s `on_mount` hooks (`NucleusWeb.ScopeHook`,
  `NucleusWeb.EnvironmentsHook`) — this module does not assign either
  itself.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.Environments
  alias Nucleus.Scope

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"environment" => environment}, _uri, socket) do
    socket = assign(socket, :environment, environment)

    socket =
      case Environments.fetch(environment, scope_token(socket)) do
        {:ok, resolved} ->
          assign(socket, environment_status: :ok, resolved_environment: resolved)

        {:error, %Error{kind: :invalid}} ->
          assign(socket, environment_status: :invalid, resolved_environment: nil)

        {:error, %Error{kind: :not_found}} ->
          assign(socket, environment_status: :not_found, resolved_environment: nil)

        {:error, %Error{kind: :unavailable}} ->
          assign(socket, environment_status: :unavailable, resolved_environment: nil)
      end

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} environments={@environments}>
      <.empty_state
        :if={@environment_status == :invalid}
        id="secrets-invalid-environment"
        icon="hero-shield-exclamation"
        message="This is not a valid environment name."
      />
      <.empty_state
        :if={@environment_status == :not_found}
        id="secrets-environment-not-found"
        icon="hero-question-mark-circle"
        message={"No environment named \"#{@environment}\" was found for this tenant."}
      />
      <.empty_state
        :if={@environment_status == :unavailable}
        id="secrets-validation-unavailable"
        icon="hero-exclamation-triangle"
        message="Can't verify this environment right now. Try again shortly."
      />
    </Layouts.app>
    """
  end

  defp scope_token(socket) do
    case socket.assigns[:current_scope] do
      %Scope{token: token} -> token
      _ -> nil
    end
  end
end
