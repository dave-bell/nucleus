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

  ## Warning sits below the key pair, not above it

  The two values render first, the warning directly beneath them, and the
  dismiss button last — the operator's eyes land on the ID/secret pair,
  read the warning immediately below without a jump back up the panel, then
  reach the button right after. Leading with the warning (as an earlier
  revision did) forced a look-down-then-back-up round trip for no benefit;
  the modal's own title and this component's dismiss-only design already
  signal "this is the one chance," so the warning does not need to be seen
  first to do its job.

  ## Copy-button tooltips point left, not the default top

  Each value's row ends in a `copy_button/1`, whose default tooltip is a
  `.tooltip-top` pseudo-element centered horizontally over the icon-only
  button. Centered-over-the-button clips against `.modal-box`'s right edge
  regardless of how wide the box is made — the tooltip is anchored to the
  button's center either way, and the button itself sits close to that
  edge by design (the value it copies fills the rest of the row). Both
  calls below pass `tooltip_position="left"` instead, which anchors the
  tooltip's content to the left of the button — away from the edge — so
  nothing needs to clip and the box keeps `.modal-box`'s ordinary default
  width.

  ## DOM ids default to issue #38's contract, overridable for reuse

  The seven ids below are the ones #38's plan tabulates for the creation
  flow. `M2M-S6`'s rotation panel reuses this component but resolves a
  client that already exists (no `client_name` changes hands, no
  `ticket_id`), so its own DOM-id contract, if different, overrides these
  defaults rather than this component guessing at a second table.

  ## `title` is the one piece of copy that legitimately differs by caller

  Everything else below the heading — the key/value labels, the warning,
  the dismiss button — describes the secret itself and reads identically
  whether it was just created or just rotated. Only the heading names the
  action that produced it, so `title` is the one attribute `M2M-S6`
  overrides (`"Secret rotated"`) rather than forking the component for one
  word, per the ticket's own instruction to parameterise instead of
  copying.
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
  attr :title, :string, default: "Client created"
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
          {@title}
        </h2>

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
              <.copy_button
                id={@copy_client_id_dom_id}
                value={@client_id}
                label="Copy client ID"
                tooltip_position="left"
              />
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
                tooltip_position="left"
              />
            </div>
          </div>
        </div>

        <div
          id={@warning_dom_id}
          role="alert"
          class="alert alert-warning mt-4 mb-4 items-start"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 mt-0.5" />
          <span>
            Copy the secret now. It will not be shown again. If it's lost,
            the only recovery is rotating the secret.
          </span>
        </div>

        <div class="modal-action">
          <.button id={@dismiss_dom_id} type="button" variant="primary" phx-click={@on_dismiss}>
            Done
          </.button>
        </div>
      </.focus_wrap>
    </div>
    """
  end
end
