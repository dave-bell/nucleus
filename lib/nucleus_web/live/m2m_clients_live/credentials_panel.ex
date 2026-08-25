defmodule NucleusWeb.M2MClientsLive.CredentialsPanel do
  @moduledoc """
  The one-time client-credentials panel — `M2M-A08` (creation), reused
  verbatim by `M2M-S6` (#39, rotation). Built here because #38 needs it
  first, not because creation is more important than rotation.

  ## Conditionally rendered, never mounted-and-toggled

  The caller wraps this component in `:if={@credentials}` (or equivalent),
  matching `NucleusWeb.SecretsLive`'s reveal modal (`docs/adr/0012`) — the
  plaintext secret must not exist in the DOM, or in the page source, from
  the moment the LiveView mounts. A class-toggle (`modal-open`) would leave
  it there from the first render; a server-side conditional means the
  element — secret inside it — is inserted only when actually drawn, and
  **removed**, not merely hidden, on dismissal.

  ## Deliberately not `<.modal>` — no incidental-dismiss routes

  `NucleusWeb.CoreComponents.modal/1` wires the backdrop click and Escape
  through the same `data-cancel` chain as its own close button, on the
  reasoning that any of the three are equally valid ways to abandon a form.
  That reasoning does not hold here: `M2M-A08` requires the operator be able
  to copy both values *before leaving the screen*, and the wiki's own error
  matrix says a secret that scrolls out of reach is unrecoverable except by
  rotation. A backdrop click or a stray Escape while reaching for the copy
  button must not silently discard the only copy of the secret. This
  component therefore carries no `phx-click-away` and no
  `phx-window-keydown` — the dismiss button below is the *only* route out,
  by construction, not by convention.

  Focus is still pushed on mount and popped on removal
  (`JS.push_focus/1`/`JS.pop_focus/1`, the same pairing `modal/1` uses), and
  `focus_wrap/1` still traps Tab inside the panel while it is open — both
  are accessibility behaviour independent of *how* the panel closes, so
  there is no reason to drop them along with the dismiss wiring above.

  ## No `name` attribute anywhere

  Both values render into plain `<div>`s, never a form input — this panel
  is display-only, so neither value can be resubmitted to the server by an
  errant form ancestor or a copy-paste into the wrong field.

  ## DOM ids default to issue #38's contract, overridable for reuse

  The seven ids below are the ones #38's plan tabulates for the creation
  flow. `M2M-S6`'s rotation panel reuses this component but resolves a
  client that already exists (no `client_name` changes hands, no
  `ticket_id`), so its own DOM-id contract, if different, overrides these
  defaults rather than this component guessing at a second table.
  """

  use NucleusWeb, :html

  @doc """
  Renders the one-time credentials panel.

  `on_dismiss` is a `Phoenix.LiveView.JS` command (typically
  `JS.push("dismiss_credentials")`) — the caller decides what dismissal
  actually does to its own assigns; this component only renders the control
  and pushes whatever it is given.
  """
  attr :id, :string, default: "m2m-client-credentials"
  attr :client_id, :string, required: true
  attr :client_secret, :string, required: true
  attr :on_dismiss, Phoenix.LiveView.JS, required: true
  attr :client_id_dom_id, :string, default: "m2m-new-client-id"
  attr :client_secret_dom_id, :string, default: "m2m-new-client-secret"
  attr :warning_dom_id, :string, default: "m2m-client-credentials-warning"
  attr :copy_client_id_dom_id, :string, default: "copy-m2m-client-id"
  attr :copy_client_secret_dom_id, :string, default: "copy-m2m-client-secret"
  attr :dismiss_dom_id, :string, default: "m2m-client-credentials-dismiss"

  def credentials_panel(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={JS.push_focus() |> JS.focus_first(to: "##{@id}-container")}
      phx-remove={JS.pop_focus()}
      class="modal modal-open"
    >
      <.focus_wrap
        id={"#{@id}-container"}
        role="dialog"
        aria-modal="true"
        aria-labelledby={"#{@id}-title"}
        class="modal-box relative"
      >
        <h2 id={"#{@id}-title"} class="text-lg font-semibold mb-4 pr-8">
          Client created
        </h2>

        <div
          id={@warning_dom_id}
          role="alert"
          class="alert alert-warning mb-4 items-start"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 mt-0.5" />
          <span>
            This secret will not be shown again. Copy both values now — if it's
            lost, the only recovery is rotating the secret.
          </span>
        </div>

        <div class="space-y-4">
          <div>
            <div class="text-sm font-medium mb-1">Client ID</div>
            <div class="flex items-center gap-2">
              <div
                id={@client_id_dom_id}
                class="font-mono text-sm break-all select-all rounded-box bg-base-200 p-3 flex-1"
              >
                {@client_id}
              </div>
              <.copy_button id={@copy_client_id_dom_id} value={@client_id} label="Copy client ID" />
            </div>
          </div>

          <div>
            <div class="text-sm font-medium mb-1">Client secret</div>
            <div class="flex items-center gap-2">
              <div
                id={@client_secret_dom_id}
                class="font-mono text-sm break-all select-all rounded-box bg-base-200 p-3 flex-1"
              >
                {@client_secret}
              </div>
              <.copy_button
                id={@copy_client_secret_dom_id}
                value={@client_secret}
                label="Copy secret"
              />
            </div>
          </div>
        </div>

        <div class="modal-action">
          <.button id={@dismiss_dom_id} type="button" variant="primary" phx-click={@on_dismiss}>
            I've copied both values — dismiss
          </.button>
        </div>
      </.focus_wrap>
    </div>
    """
  end
end
