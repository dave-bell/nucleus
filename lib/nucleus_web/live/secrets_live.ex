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

  ## One call to `Nucleus.Secrets.list/2`, not two

  `SEC-S1`'s original placeholder called `Nucleus.Environments.fetch/2`
  directly. `SEC-S2` collapsed that into a single call to
  `Nucleus.Secrets.list/2`, which gates through `Environments.fetch/2`
  internally — this module no longer calls it, and no longer keeps a
  `resolved_environment` assign (it was assigned by the placeholder and never
  read). `current_scope` is passed to the context wholesale, per Phoenix 1.8
  scope convention.

  ## Every outcome gets its own assign and DOM id

  `Nucleus.Secrets.list/2` can succeed, or fail with any
  `Nucleus.Backend.Error.kinds/0` value from either boundary it touches
  (`:tenant_api` via the environment gate, `:secrets` via the store) — this
  `case` must handle all of them without crashing:

  | Outcome | `:environment_status` | DOM id |
  |---|---|---|
  | `{:ok, refs}` | `:ok` | `#secrets-table` / `#secrets-empty` |
  | `kind: :invalid` | `:invalid` | `#secrets-invalid-environment` |
  | `kind: :not_found` | `:not_found` | `#secrets-environment-not-found` |
  | `kind: :unavailable, boundary: :tenant_api` | `:validation_unavailable` | `#secrets-validation-unavailable` |
  | `kind: :unavailable, boundary: :secrets` | `:secrets_unavailable` | `#secrets-unavailable` |
  | `kind: :auth_expired` (either boundary) | `:auth_expired` | `#secrets-auth-expired` |
  | anything else (`:already_exists`, `:not_configured`) | `:secrets_unavailable` | `#secrets-unavailable` |

  `:invalid` and `:not_found` only ever arrive with `boundary: :tenant_api` —
  the store is never reached once the gate rejects a name. The two
  `:unavailable` outcomes are otherwise identical (`kind: :unavailable`) and
  are told apart only by `boundary`, which is why this `case` matches on it
  explicitly rather than collapsing them — collapsing "not found" and
  "unavailable" would misinform the user about a real outage (`SEC-A17`), and
  the same reasoning applies to the store's own outage.

  `:auth_expired` is `SEC-S7`'s concern — this module renders a placeholder
  and does not implement retry semantics for it. Every other, unlisted kind
  (there are none today, but `kinds/0` could grow one) falls back to the same
  `:secrets_unavailable` rendering rather than crashing.

  Every branch keeps the shell intact (`<Layouts.app>`, `#tenant-identifier`)
  so the user can navigate away — a crashed LiveView is not an acceptable
  rendering of any of these. The raw environment name is never echoed
  unescaped — HEEx's default escaping is not defeated with `raw/1`.

  ## Values are never in reach, never mind on screen

  `Nucleus.Secrets.list/2` returns `%Nucleus.Secrets.SecretRef{}` structs,
  which have no `value` field — this module cannot render, prefetch, or leak
  a value during listing even by accident. The table has no "Value" column at
  all: not a plaintext one, and not a masked one either. A mask is only ever
  a promise that nothing was leaked, and it still has to be careful not to
  encode the real length; a column that does not exist makes no promise to
  break.

  ## Row DOM ids are a hash of the ARN, not the key (`SEC-S2` decision 2)

  The ARN is unique per secret and stable across renders (it encodes the
  path and key, not the value), so it survives the `stream_insert/3` that
  `SEC-S5` performs when a row's edit state changes. An opaque id is worse to
  select against, so each row also carries `data-key={ref.key}` — later
  tickets should select on `[data-key="DATABASE_URL"]`, not on the row id,
  and must not recompute the hash in a test.

  `current_scope` and `environments` come from the `:authenticated`
  `live_session`'s `on_mount` hooks (`NucleusWeb.ScopeHook`,
  `NucleusWeb.EnvironmentsHook`) — this module does not assign either
  itself.

  ## Copy affordances read from the full value, not the truncated span (`SEC-A02`)

  `<.copy_button>` (`SEC-S3`) is given `ref.path`/`ref.arn` directly — the
  same full strings the row's DOM id is hashed from — not the neighbouring
  `<span class="truncate">`'s text. Truncation there is CSS-only; the full
  value is always present in the DOM, and the button's `data-value` must
  carry it or a copy silently produces a broken, visually-truncated value.
  Button ids are suffixed with the row's `dom_id`, so they stay unique and
  stable across the same `stream_insert/3` churn the row id itself is
  designed to survive. In-row copy buttons are icon-only, with the label as a
  tooltip — see `NucleusWeb.CoreComponents.copy_button/1`.

  Path and ARN are truncated more often than not, so each carries a daisyUI
  tooltip with its full value. The tooltip sits on a **wrapper** span with the
  truncating span nested inside it, not on the truncating span itself:
  `truncate` includes `overflow: hidden`, and daisyUI renders the tooltip as
  an absolutely-positioned pseudo-element *inside* the element carrying
  `.tooltip` — put both on one span and the tooltip is clipped by the very
  rule that made it necessary. This replaced a plain `title` attribute, which
  had a browser-controlled delay, no styling, and no wrapping for a string
  this long.

  ## Reveal is a modal, and the modal is only in the DOM while it is open (`SEC-S4`)

  `:revealed` holds `nil` or exactly one `%Nucleus.Secrets.Secret{}` — the
  one the modal is showing. There is nowhere else in this module a plaintext
  value can be, and there is no cache: `handle_event("reveal", ...)` always
  calls `Nucleus.Secrets.reveal/3` again, a fresh `Store.get_secret/2` call
  and a fresh `secret_viewed` audit record every time (`SEC-A03`).

  The `<.modal>` is wrapped in `:if={@revealed}` rather than left mounted and
  toggled with daisyUI's `modal-open` class. Toggling a class only stops the
  markup being *painted* — the plaintext would sit in the DOM, and in the
  page source, from the moment the modal existed. Wrapping it means the
  value is written into a payload only when the modal is actually drawn, and
  the element (with the value in it) is removed on dismissal, not just
  hidden. `show={true}` goes with that: an element that only exists while
  open is always inserted already-open, via the component's `phx-mounted`.

  Dismissal is `SEC-A04`'s "Hide", by whichever of the four routes the user
  takes — the X, the Close button, Escape, or a click on the backdrop.
  `<.modal>` funnels the X, Escape, and the backdrop through its own
  `data-cancel` attribute, so `on_cancel={JS.push("hide")}` is the single
  wiring point for those three. The Close button pushes `"hide"` directly
  instead of routing through `data-cancel`: it needs no client-side work that
  `phx-remove` does not already do (removing the element runs the
  component's `hide_modal/2`, so focus is restored either way), and a plain
  event is one `render_click/1` a test can actually drive, where a
  `JS.exec/2` command is not. `handle_event("hide", ...)` just sets
  `:revealed` back to `nil`. Hiding is local-only: no backend call and no
  audit event — the wiki's audit catalogue has no event for hiding a value.

  **Nothing about a row depends on `:revealed`**, which is why no reveal or
  hide re-streams anything. The row's control always reads "View": while the
  modal is open it is behind a backdrop and cannot be clicked, so a "Hide"
  label there would be state nobody can act on, and the modal's own dismiss
  controls are the hide affordance `SEC-A04` asks for (see
  `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md`). This
  also keeps the stream free of reveal state entirely: it carries `SecretRef`
  structs, which have no `value` field, and it is never re-inserted for a
  reveal.

  A failed reveal (`SEC-A05`) leaves `:revealed` as `nil` — no modal opens,
  so there is no blank dialog to explain, and a kind-specific flash on the
  underlying page says what happened. `:auth_expired` does not yet have
  `SEC-S7`'s shared handler to delegate to (that ticket is still open) — the
  copy here is deliberately generic and will move under that handler once it
  lands, not duplicate it.

  `:revealed` is reset to `nil` on every `handle_params/3` call, so patching
  between environments (or navigating back to this same route) never carries
  a previously-revealed plaintext value across.

  ## Editing lives inside the reveal modal, not a row (`SEC-S5`)

  The plan this ticket originally shipped with (issue #13) specified the
  reveal-before-edit gate against "the `:revealed` map established by
  SEC-S4" and a row-level Edit button. Both are stale by the time this
  module implements them: `#43`/ADR-0012 (above) already narrowed
  `:revealed` to a single `%Secret{}` or `nil`, so there is no map, and
  reveal state now lives only as long as the modal is open — a row-level
  Edit button would almost always hit the gate and dead-end, since a user
  who reveals, dismisses, and then clicks a row's Edit has nothing left to
  edit against. See `docs/adr/0012-...md`'s own "Negative" consequences and
  `living-notes.md`'s Technical Debt entry for this ticket, both of which
  record the correction this module implements:

  - **The gate checks `socket.assigns.revealed` is a `%Secret{}` whose `key`
    matches the incoming key** — still server-side, in `handle_event/3`,
    still re-checked on save. `handle_event("edit", %{"key" => key}, ...)`
    and `handle_event("save_edit", %{"key" => key, ...}, ...)` both pattern
    match `%Secret{key: ^key}` and reject (flash, no other effect) on
    anything else, including no reveal at all. Hiding the Edit button unless
    revealed is UI convenience; a `phx-click` can be dispatched directly
    against the socket regardless of what is rendered, so the check here is
    the actual gate.
  - **Edit swaps the modal's own content, in place** — there is no second
    `<.modal>`. `:editing` (boolean) toggles between the value-display
    content and a `to_form/2`-built edit form, both inside the same
    `#secret-modal`. This sidesteps ADR-0012's recorded `focusStack`
    gotcha entirely: two modals stacked would have the inner one's dismissal
    consume the outer one's saved `JS.push_focus/1` call, and swapping
    content in one modal never opens a second one.
  - **`SEC-A07`'s re-masking is a consequence of `:revealed` going to `nil`
    on save success, not a separate step.** Because the modal is wrapped in
    `:if={@revealed}` (see above), clearing `:revealed` removes the modal —
    plaintext and edit form both — from the DOM in the same assign that
    confirms success. There is nothing else to re-mask.
  - **Save starts disabled and enables only once the entered value differs
    from `@revealed.value`.** A dirty-check, not merely non-empty — decided
    directly for this ticket rather than following the plan's DOM id table
    literally, since that table assumed a row-scoped edit control this
    module does not have. The disabled attribute is UI convenience only;
    the reveal-before-edit gate above is what actually stops a save.
  - **Cancel clears `:editing`/`:edit_form` only.** `:revealed` is
    untouched — `SEC-A06`'s "cancel to discard the change" is not
    `SEC-A04`'s hide, and the value stays revealed exactly as it does today
    when a user dismisses nothing at all.

  ## Creating a secret is its own conditionally-rendered modal, mutually exclusive with reveal (`SEC-S6`)

  `:creating` (boolean) and `:create_form` follow the same `:if`-wrapped
  shape ADR-0012 established for `:revealed` — the modal (`#new-secret-modal`)
  only exists in the DOM while `:creating` is true, and `handle_event/3`
  drives it in and out exactly as `edit`/`hide` drive the reveal modal, not a
  client-side `show_modal/2`/`hide_modal/2` pair. This was a deliberate
  choice over the "mounted and toggled" usage ADR-0012 calls acceptable for
  this form (a key and a not-yet-created value are not the same risk as an
  already-stored plaintext secret) — using the same conditional shape as the
  reveal modal means `on_cancel={JS.push("cancel_new")}` closes it the same
  way `on_cancel={JS.push("hide")}` closes the reveal modal (removal fires
  the component's own `phx-remove`), with no second client-side code path to
  keep in sync.

  **Opening either modal closes the other.** `"new_secret"` resets
  `:revealed`/`:editing`/`:edit_form`/`:edit_error` to their closed state in
  the same assign that opens the create modal, and `"reveal"` does the
  mirror on `:creating`/`:create_form`/`:create_error`. Nothing renders two
  `<.modal>`s at once as a structural guarantee, not merely as an unlikely
  sequence of clicks — a client can dispatch `phx-click` events directly
  regardless of which button is visually reachable behind a backdrop, the
  same reasoning every other gate in this module already relies on. This is
  the concrete fix for the `focusStack`/`JS.pop_focus/1` double-pop risk
  ADR-0012 and `living-notes.md` both flag by name against this ticket: two
  conditionally-rendered modals stacked would have the inner one's dismissal
  consume the outer one's saved focus, so this module never lets both exist
  at once rather than fixing the interaction after the fact.

  **`:secret_keys` is kept in lock-step with the stream, not fetched separately
  for the duplicate check.** `fetch_secrets/2` — already the one place
  `:secret_count` and the stream are set — also assigns `:secret_keys` (the
  plain list of keys from the same `Nucleus.Secrets.list/2` call) so
  `NucleusWeb.SecretsLive.CreateForm.changeset/3`'s `SEC-A10` duplicate check
  always compares against what is actually currently rendered, with no
  second store call and no risk of the two drifting apart.

  **A successful create re-lists rather than computing a stream insertion
  position.** `Nucleus.Secrets.list/2` already sorts
  case-insensitively — recomputing that ordering here to call
  `stream_insert/3` at the right index would duplicate logic that already
  exists and risks getting the tiebreak wrong. `save_new_secret/3` calls
  `fetch_secrets/2` again on success, which re-streams with `reset: true`;
  this also means a first-secret creation flips `:secret_count` from `0` and
  swaps `#secrets-empty` for `#secrets-table` for free, the same way
  `SEC-A07`'s re-masking falls out of `:revealed` going to `nil` rather than
  being a separate step.

  **`Nucleus.Secrets.Key.validate/1` and `Nucleus.Secrets.Value.validate/1`
  run twice, deliberately.** `CreateForm.changeset/3` runs both — the same
  functions `Nucleus.Secrets.create/4` runs again before ever reaching the
  store. The first run is `SEC-A10`/`SEC-A11`'s fast, advisory feedback while
  typing; the second is what actually stops an invalid `save_new` dispatched
  directly, bypassing the disabled submit button the same way `save_edit`'s
  reveal-before-edit gate cannot be satisfied by hiding a button alone.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.Secrets
  alias Nucleus.Secrets.Secret
  alias Nucleus.Secrets.SecretRef
  alias Nucleus.Secrets.Value
  alias NucleusWeb.SecretsLive.CreateForm
  alias NucleusWeb.SecretsLive.EditForm

  @modal_id "secret-modal"
  @create_modal_id "new-secret-modal"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> stream_configure(:secrets, dom_id: &dom_id/1)
      |> stream(:secrets, [])

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"environment" => environment}, _uri, socket) do
    socket =
      socket
      |> assign(:environment, environment)
      |> assign(:revealed, nil)
      |> assign(:editing, false)
      |> assign(:edit_form, nil)
      |> assign(:edit_error, nil)
      |> assign(:creating, false)
      |> assign(:create_form, nil)
      |> assign(:create_error, nil)
      |> fetch_secrets(environment)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("reveal", %{"key" => key}, socket) do
    case Secrets.reveal(socket.assigns.environment, key, socket.assigns.current_scope) do
      {:ok, secret} ->
        socket =
          socket
          |> assign(:revealed, secret)
          |> assign(:editing, false)
          |> assign(:edit_form, nil)
          |> assign(:edit_error, nil)
          # Mutual exclusion with the create modal — see the moduledoc's
          # "Creating a secret" section for why this side structurally
          # avoids ADR-0012's focusStack double-pop risk rather than fixing
          # it after the fact.
          |> assign(:creating, false)
          |> assign(:create_form, nil)
          |> assign(:create_error, nil)

        {:noreply, socket}

      {:error, %Error{} = error} ->
        {:noreply, put_flash(socket, :error, reveal_error_message(error))}
    end
  end

  # Every dismissal route the modal offers — X, Close, Escape, backdrop —
  # arrives here, carrying no params: there is only ever one revealed secret,
  # so there is nothing to identify.
  @impl Phoenix.LiveView
  def handle_event("hide", _params, socket) do
    socket =
      socket
      |> assign(:revealed, nil)
      |> assign(:editing, false)
      |> assign(:edit_form, nil)
      |> assign(:edit_error, nil)

    {:noreply, socket}
  end

  # `SEC-A06`'s reveal-before-edit gate: `key` is forgeable via
  # `phx-value-key`, exactly like `reveal/3`'s `key` argument, so this
  # pattern-matches `socket.assigns.revealed` — never trusts the UI having
  # hidden the Edit button — and rejects anything that is not a `%Secret{}`
  # for this exact key. Hiding a button is convenience; this check is the
  # gate.
  @impl Phoenix.LiveView
  def handle_event("edit", %{"key" => key}, socket) do
    case socket.assigns.revealed do
      %Secret{key: ^key} = secret ->
        socket =
          socket
          |> assign(:editing, true)
          |> assign(:edit_form, build_edit_form(secret.value))
          |> assign(:edit_error, nil)

        {:noreply, socket}

      _not_revealed ->
        {:noreply, put_flash(socket, :error, "Reveal the value before editing it.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate_edit", %{"secret" => params}, socket) do
    if socket.assigns.editing do
      changeset =
        %EditForm{}
        |> EditForm.changeset(params)
        |> Map.put(:action, :validate)

      {:noreply, assign(socket, :edit_form, to_form(changeset, as: :secret))}
    else
      {:noreply, socket}
    end
  end

  # Re-checked here, not only in "edit" — the reveal could have been cleared
  # (a hide, a navigation) between opening the form and submitting it.
  @impl Phoenix.LiveView
  def handle_event("save_edit", %{"key" => key, "secret" => params}, socket) do
    case socket.assigns.revealed do
      %Secret{key: ^key} ->
        changeset =
          %EditForm{}
          |> EditForm.changeset(params)
          |> Map.put(:action, :validate)

        if changeset.valid? do
          save_edit(socket, key, Ecto.Changeset.get_field(changeset, :value))
        else
          {:noreply, assign(socket, :edit_form, to_form(changeset, as: :secret))}
        end

      _not_revealed ->
        {:noreply, put_flash(socket, :error, "Reveal the value before editing it.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("cancel_edit", _params, socket) do
    # `:revealed` is untouched — cancelling an edit is not hiding
    # (`SEC-A04`), and no backend call or audit event happens on this path.
    socket =
      socket
      |> assign(:editing, false)
      |> assign(:edit_form, nil)
      |> assign(:edit_error, nil)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("new_secret", _params, socket) do
    socket =
      socket
      # Mutual exclusion with the reveal modal — see the moduledoc.
      |> assign(:revealed, nil)
      |> assign(:editing, false)
      |> assign(:edit_form, nil)
      |> assign(:edit_error, nil)
      |> assign(:creating, true)
      |> assign(:create_form, build_create_form(socket.assigns.secret_keys))
      |> assign(:create_error, nil)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("validate_new", %{"new_secret" => params}, socket) do
    changeset =
      %CreateForm{}
      |> CreateForm.changeset(params, socket.assigns.secret_keys)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :create_form, to_form(changeset, as: :new_secret))}
  end

  # Re-validated here, not only via `phx-change` — `SEC-A10`/`SEC-A11`
  # require server-side enforcement, since a disabled submit button is UI
  # convenience only: `save_new` can be dispatched directly, bypassing
  # whatever `validate_new` already rejected client-side.
  @impl Phoenix.LiveView
  def handle_event("save_new", %{"new_secret" => params}, socket) do
    changeset =
      %CreateForm{}
      |> CreateForm.changeset(params, socket.assigns.secret_keys)
      |> Map.put(:action, :validate)

    if changeset.valid? do
      save_new_secret(
        socket,
        Ecto.Changeset.get_field(changeset, :key),
        Ecto.Changeset.get_field(changeset, :value)
      )
    else
      {:noreply, assign(socket, :create_form, to_form(changeset, as: :new_secret))}
    end
  end

  # Every dismissal route the modal offers — Cancel, Escape, backdrop —
  # arrives here, carrying no params, mirroring `"hide"` above.
  @impl Phoenix.LiveView
  def handle_event("cancel_new", _params, socket) do
    socket =
      socket
      |> assign(:creating, false)
      |> assign(:create_form, nil)
      |> assign(:create_error, nil)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("retry", _params, socket) do
    {:noreply, fetch_secrets(socket, socket.assigns.environment)}
  end

  defp save_edit(socket, key, value) do
    case Secrets.update(socket.assigns.environment, key, value, socket.assigns.current_scope) do
      {:ok, ref} ->
        socket =
          socket
          # `SEC-A07`: re-masked because `:revealed` goes to `nil`, which
          # also removes the modal (and the edit form inside it) from the
          # DOM — there is no separate re-mask step.
          |> assign(:revealed, nil)
          |> assign(:editing, false)
          |> assign(:edit_form, nil)
          |> assign(:edit_error, nil)
          |> put_flash(:info, "#{key} was updated.")
          |> stream_insert(:secrets, ref)

        {:noreply, socket}

      {:error, %Error{} = error} ->
        # `SEC-A08`: the form stays open (`:editing` untouched, `:edit_form`
        # keeps the submitted value via the caller's own reassignment below)
        # and `:revealed` is untouched — a failure must not re-mask.
        changeset =
          %EditForm{}
          |> EditForm.changeset(%{"value" => value})
          |> Map.put(:action, :validate)

        socket =
          socket
          |> assign(:edit_form, to_form(changeset, as: :secret))
          |> assign(:edit_error, edit_error_message(error))

        {:noreply, socket}
    end
  end

  # `SEC-A12`'s rejection and any other failure both leave `:creating` and
  # the entered `key`/`value` untouched (rebuilt into a fresh changeset
  # below so they survive) — never a silent discard, matching `save_edit/3`'s
  # `SEC-A08` reasoning above.
  defp save_new_secret(socket, key, value) do
    case Secrets.create(socket.assigns.environment, key, value, socket.assigns.current_scope) do
      {:ok, _ref} ->
        socket =
          socket
          |> assign(:creating, false)
          |> assign(:create_form, nil)
          |> assign(:create_error, nil)
          |> put_flash(:info, "#{key} was created.")
          # `SEC-A09`: re-lists rather than computing a stream insertion
          # position — see the moduledoc's "Creating a secret" section.
          # This also updates `:secret_count`/`:secret_keys`, which is what
          # flips `#secrets-empty` to `#secrets-table` on a first secret.
          |> fetch_secrets(socket.assigns.environment)

        {:noreply, socket}

      {:error, %Error{kind: :already_exists}} ->
        changeset =
          %CreateForm{}
          |> CreateForm.changeset(%{"key" => key, "value" => value}, socket.assigns.secret_keys)
          |> Ecto.Changeset.add_error(:key, "already exists in this environment")
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :create_form, to_form(changeset, as: :new_secret))}

      {:error, %Error{} = error} ->
        changeset =
          %CreateForm{}
          |> CreateForm.changeset(%{"key" => key, "value" => value}, socket.assigns.secret_keys)
          |> Map.put(:action, :validate)

        socket =
          socket
          |> assign(:create_form, to_form(changeset, as: :new_secret))
          |> assign(:create_error, create_error_message(error))

        {:noreply, socket}
    end
  end

  defp fetch_secrets(socket, environment) do
    case Secrets.list(environment, socket.assigns.current_scope) do
      {:ok, refs} ->
        socket
        |> assign(
          environment_status: :ok,
          secret_count: length(refs),
          secret_keys: Enum.map(refs, & &1.key)
        )
        |> stream(:secrets, refs, reset: true)

      {:error, %Error{kind: :invalid, boundary: :tenant_api}} ->
        assign(socket, environment_status: :invalid, secret_count: 0, secret_keys: [])

      {:error, %Error{kind: :not_found, boundary: :tenant_api}} ->
        assign(socket, environment_status: :not_found, secret_count: 0, secret_keys: [])

      {:error, %Error{kind: :unavailable, boundary: :tenant_api}} ->
        assign(socket,
          environment_status: :validation_unavailable,
          secret_count: 0,
          secret_keys: []
        )

      {:error, %Error{kind: :unavailable, boundary: :secrets}} ->
        assign(socket, environment_status: :secrets_unavailable, secret_count: 0, secret_keys: [])

      {:error, %Error{kind: :auth_expired}} ->
        assign(socket, environment_status: :auth_expired, secret_count: 0, secret_keys: [])

      {:error, %Error{}} ->
        assign(socket, environment_status: :secrets_unavailable, secret_count: 0, secret_keys: [])
    end
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
        :if={@environment_status == :validation_unavailable}
        id="secrets-validation-unavailable"
        icon="hero-exclamation-triangle"
        message="Can't verify this environment right now. Try again shortly."
      />
      <.empty_state
        :if={@environment_status == :secrets_unavailable}
        id="secrets-unavailable"
        icon="hero-exclamation-triangle"
        message="Can't reach the secrets store right now. Try again shortly."
      >
        <:action>
          <.button phx-click="retry">Retry</.button>
        </:action>
      </.empty_state>
      <.empty_state
        :if={@environment_status == :auth_expired}
        id="secrets-auth-expired"
        icon="hero-lock-closed"
        message="This environment's secrets can't be reached right now."
      />
      <div :if={@environment_status == :ok}>
        <div class="flex items-center justify-between gap-4 pb-4">
          <h1 class="text-lg font-semibold">Secrets</h1>
          <.button id="secrets-create-button" phx-click="new_secret">New secret</.button>
        </div>

        <.empty_state
          :if={@secret_count == 0}
          id="secrets-empty"
          icon="hero-inbox"
          message="No secrets found for this environment."
        />

        <div :if={@secret_count > 0} id="secrets-table">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Key</th>
                <th>Path</th>
                <th>ARN</th>
                <th>Last modified</th>
                <th><span class="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody id="secrets-table-body" phx-update="stream">
              <tr :for={{dom_id, ref} <- @streams.secrets} id={dom_id} data-key={ref.key}>
                <td class="font-medium">{ref.key}</td>
                <td>
                  <div class="flex items-center gap-1">
                    <span class="tooltip max-w-xs" data-tip={ref.path}>
                      <span class="block truncate">{ref.path}</span>
                    </span>
                    <.copy_button id={"copy-path-#{dom_id}"} value={ref.path} label="Copy path" />
                  </div>
                </td>
                <td>
                  <div class="flex items-center gap-1">
                    <span class="tooltip max-w-xs" data-tip={ref.arn}>
                      <span class="block truncate">{ref.arn}</span>
                    </span>
                    <.copy_button id={"copy-arn-#{dom_id}"} value={ref.arn} label="Copy ARN" />
                  </div>
                </td>
                <td class="whitespace-nowrap">{format_last_modified(ref.last_modified)}</td>
                <td class="text-right">
                  <button
                    id={reveal_id(dom_id)}
                    type="button"
                    class="btn btn-sm"
                    phx-click="reveal"
                    phx-value-key={ref.key}
                  >
                    View
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <%!--
        Only in the DOM while it is open — the plaintext is never rendered
        into a hidden element. See the moduledoc, "Reveal is a modal".
        --%>
        <.modal :if={@revealed} id={modal_id()} show on_cancel={JS.push("hide")}>
          <:title>{@revealed.key}</:title>
          <%= if @editing do %>
            <.form
              for={@edit_form}
              id="secret-edit-form"
              phx-change="validate_edit"
              phx-submit="save_edit"
            >
              <input type="hidden" name="key" value={@revealed.key} />
              <.input
                field={@edit_form[:value]}
                id="secret-edit-value"
                type="textarea"
                label="Value"
                rows="6"
                class="w-full textarea font-mono text-sm"
              />
              <div id="secret-edit-count" class="text-xs text-base-content/70 text-right mt-1">
                {edit_value_length(@edit_form)}/{Value.max_length()} characters
              </div>
              <p
                :if={@edit_error}
                id="secret-edit-error"
                role="alert"
                class="text-error text-sm mt-2"
              >
                {@edit_error}
              </p>
              <div class="modal-action">
                <.button id="cancel-edit" type="button" phx-click="cancel_edit">
                  Cancel
                </.button>
                <.button
                  id="save-edit"
                  type="submit"
                  variant="primary"
                  disabled={not edit_dirty?(@edit_form, @revealed.value)}
                  phx-disable-with="Saving..."
                >
                  Save
                </.button>
              </div>
            </.form>
          <% else %>
            <%!--
            `tabindex="0"` is not decoration: `max-h-60` is about twelve lines
            of `font-mono text-sm`, and a PEM key or a service-account JSON
            blob runs past that. Without it the region scrolls for a mouse
            and is unreachable for a keyboard, since `focus_wrap` cycles only
            the buttons. `role="region"` + a name is what makes a focus stop
            on non-interactive content announce as something rather than
            nothing.
            --%>
            <div
              id="secret-modal-value"
              tabindex="0"
              role="region"
              aria-label="Secret value"
              class="font-mono text-sm break-all select-all rounded-box bg-base-200 p-3 max-h-60 overflow-y-auto"
            >
              {@revealed.value}
            </div>
            <div class="modal-action">
              <.button
                id="edit-secret"
                variant="primary"
                phx-click="edit"
                phx-value-key={@revealed.key}
              >
                Edit
              </.button>
              <.copy_button
                id="secret-modal-copy"
                value={@revealed.value}
                label="Copy value"
                show_label
              />
              <.button id="secret-modal-dismiss" phx-click="hide">Close</.button>
            </div>
          <% end %>
        </.modal>

        <%!--
        Only in the DOM while it is open, mirroring the reveal modal above —
        see the moduledoc's "Creating a secret" section for why the same
        `:if`-wrapped shape was chosen over leaving this mounted and toggled.
        --%>
        <.modal
          :if={@creating}
          id={create_modal_id()}
          show
          on_cancel={JS.push("cancel_new")}
        >
          <:title>New secret</:title>
          <.form
            for={@create_form}
            id="new-secret-form"
            phx-change="validate_new"
            phx-submit="save_new"
          >
            <.input
              field={@create_form[:key]}
              id="new-secret-key"
              type="text"
              label="Key"
              placeholder="DATABASE_URL"
              class="w-full input font-mono text-sm"
            />
            <p class="text-xs text-base-content/70 -mt-1 mb-2">
              Convention: <code>UPPER_SNAKE_CASE</code>, e.g. <code>DATABASE_URL</code>. Not enforced.
            </p>
            <.input
              field={@create_form[:value]}
              id="new-secret-value"
              type="textarea"
              label="Value"
              rows="6"
              class="w-full textarea font-mono text-sm"
            />
            <div
              id="new-secret-value-count"
              class={[
                "text-xs text-right mt-1",
                if(create_value_length(@create_form) > Value.max_length(),
                  do: "text-error font-semibold",
                  else: "text-base-content/70"
                )
              ]}
            >
              {create_value_length(@create_form)}/{Value.max_length()} characters
            </div>
            <p
              :if={@create_error}
              id="new-secret-error"
              role="alert"
              class="text-error text-sm mt-2"
            >
              {@create_error}
            </p>
            <div class="modal-action">
              <.button id="new-secret-cancel" type="button" phx-click="cancel_new">
                Cancel
              </.button>
              <.button
                id="new-secret-submit"
                type="submit"
                variant="primary"
                disabled={not @create_form.source.valid?}
                phx-disable-with="Creating..."
              >
                Create
              </.button>
            </div>
          </.form>
        </.modal>
      </div>
    </Layouts.app>
    """
  end

  # A module attribute, not an assign — `@modal_id` inside `~H` would mean
  # `assigns.modal_id`.
  defp modal_id, do: @modal_id

  defp create_modal_id, do: @create_modal_id

  defp dom_id(%SecretRef{arn: arn}) do
    "secret-" <> (:crypto.hash(:sha256, arn) |> Base.url_encode64(padding: false))
  end

  defp reveal_id("secret-" <> hash), do: "reveal-" <> hash

  defp reveal_error_message(%Error{kind: :not_found}) do
    "This secret no longer exists. It may have been removed outside Nucleus."
  end

  defp reveal_error_message(%Error{kind: :auth_expired}) do
    "This environment's secrets can't be reached right now."
  end

  defp reveal_error_message(%Error{kind: :unavailable}) do
    "Can't retrieve this secret's value right now. Try again shortly."
  end

  defp reveal_error_message(%Error{kind: :invalid}) do
    "That secret key isn't valid."
  end

  defp reveal_error_message(%Error{}) do
    "Can't retrieve this secret's value right now. Try again shortly."
  end

  # `SEC-A08`'s kind-specific copy for a failed save — mirrors
  # `reveal_error_message/1`'s shape, but distinct text: a reveal failure
  # means no dialog opens at all, where a save failure means the dialog (and
  # the user's typed value) must stay exactly where it was.
  defp edit_error_message(%Error{kind: :not_found}) do
    "This secret no longer exists. It may have been removed outside Nucleus."
  end

  defp edit_error_message(%Error{kind: :auth_expired}) do
    "This environment's secrets can't be reached right now."
  end

  defp edit_error_message(%Error{kind: :unavailable}) do
    "Can't save this value right now. Try again shortly."
  end

  defp edit_error_message(%Error{kind: :invalid}) do
    "That value isn't valid."
  end

  defp edit_error_message(%Error{}) do
    "Can't save this value right now. Try again shortly."
  end

  # Fresh each time, never reused across a reveal/edit cycle — a schemaless
  # `%EditForm{}` prefilled with the currently-revealed value, unvalidated
  # (`action: nil`) so opening the form shows no errors before the user has
  # typed anything.
  defp build_edit_form(value) do
    %EditForm{}
    |> EditForm.changeset(%{"value" => value})
    |> to_form(as: :secret)
  end

  defp edit_value_length(form) do
    form[:value].value
    |> to_string()
    |> String.length()
  end

  # Save starts disabled and enables only once the entered value differs
  # from the currently-revealed one — decided directly for this ticket, not
  # merely "non-empty". Convenience only: the reveal-before-edit gate in
  # `handle_event("save_edit", ...)` is what actually stops a save, not this
  # attribute.
  defp edit_dirty?(form, original_value) do
    to_string(form[:value].value) != to_string(original_value)
  end

  # `SEC-A12`/`SEC-A10`/`SEC-A11`'s kind-specific copy for a failed create —
  # mirrors `edit_error_message/1`'s shape. `:already_exists` (`SEC-A12`) is
  # handled separately, as a field-level error attached directly to `:key`
  # rather than through this function — see `save_new_secret/3`.
  defp create_error_message(%Error{kind: :auth_expired}) do
    "This environment's secrets can't be reached right now."
  end

  defp create_error_message(%Error{kind: :unavailable}) do
    "Can't create this secret right now. Try again shortly."
  end

  defp create_error_message(%Error{kind: :invalid}) do
    "That key or value isn't valid."
  end

  defp create_error_message(%Error{}) do
    "Can't create this secret right now. Try again shortly."
  end

  # Fresh each time, never reused across an open/cancel cycle — an unvalidated
  # (`action: nil`) empty `%CreateForm{}` so opening the form shows no errors
  # before the user has typed anything, mirroring `build_edit_form/1`.
  defp build_create_form(existing_keys) do
    %CreateForm{}
    |> CreateForm.changeset(%{}, existing_keys)
    |> to_form(as: :new_secret)
  end

  defp create_value_length(form) do
    form[:value].value
    |> to_string()
    |> String.length()
  end

  defp format_last_modified(nil), do: "—"

  defp format_last_modified(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end
end
