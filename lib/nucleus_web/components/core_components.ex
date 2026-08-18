defmodule NucleusWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: NucleusWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Renders a status pill.

  Needed by `ENV-A03` (Active/Archived) and useful for error states.

  ## Examples

      <.badge variant="success">Active</.badge>
      <.badge variant="warning">Archived</.badge>
  """
  attr :variant, :string, default: "neutral", values: ~w(neutral info success warning error)
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def badge(assigns) do
    variants = %{
      "neutral" => "badge-neutral",
      "info" => "badge-info",
      "success" => "badge-success",
      "warning" => "badge-warning",
      "error" => "badge-error"
    }

    assigns = assign(assigns, :variant_class, Map.fetch!(variants, assigns.variant))

    ~H"""
    <span class={["badge", @variant_class, @class]} {@rest}>{render_slot(@inner_block)}</span>
    """
  end

  @doc """
  Renders a panel container.

  ## Examples

      <.card>
        <p>Panel content</p>
      </.card>
  """
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div class={["card bg-base-100 border border-base-300 shadow-sm", @class]} {@rest}>
      <div class="card-body">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  @doc """
  Renders an empty state — `SEC-A14`, `NAV-A07`.

  The `:action` slot is load-bearing, not decorative: `SEC-A14` requires the
  create affordance stay available even when there is nothing to show, and
  `NAV-A07`/the wiki's error matrix require this same component for a failed
  load, not a distinct error state — callers decide what `message` to pass,
  this component does not distinguish "empty" from "failed to load".
  """
  attr :id, :string, required: true
  attr :icon, :string, default: "hero-inbox"
  attr :message, :string, required: true
  attr :class, :any, default: nil

  slot :action, doc: "the load-bearing action shown alongside the empty message, if any"

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class={["flex flex-col items-center justify-center gap-3 py-12 text-center", @class]}
    >
      <.icon name={@icon} class="size-10 text-base-content/40" />
      <p class="text-base-content/70">{@message}</p>
      <div :if={@action != []} class="mt-1">{render_slot(@action)}</div>
    </div>
    """
  end

  @doc """
  Renders a modal — for `SEC-A09`'s creation form and `SEC-A13`'s dismissal
  requirements.

  Built on daisyUI's `.modal`/`.modal-box` classes (`AGENTS.md`) and
  `Phoenix.Component.focus_wrap/1` for the Tab focus trap — `focus_wrap`
  ships its own `Phoenix.FocusWrap` JS hook as part of `phoenix_live_view`,
  so no colocated hook is needed here.

  Closes on backdrop click (`phx-click-away`), Escape (`phx-window-keydown`),
  or an explicit close/cancel control — all three route through the same
  `data-cancel` attribute, so `on_cancel` (a `Phoenix.LiveView.JS` command)
  always runs regardless of which one the user picks.

  `show_modal/2` and `hide_modal/2` toggle daisyUI's `modal-open` trigger
  class and use `JS.push_focus/1` + `JS.pop_focus/1` to return focus to
  whatever triggered the modal on close — `SEC-A13`'s "focus returns to a
  sensible place in the underlying page" is this pairing's job, not the
  LiveView's.

  ## Examples

      <.button phx-click={show_modal("confirm-modal")}>Show modal</.button>

      <.modal id="confirm-modal" on_cancel={JS.push("cancel_confirm")}>
        <:title>Are you sure?</:title>
        This cannot be undone.
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true
  slot :title

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      class="modal"
    >
      <.focus_wrap
        id={"#{@id}-container"}
        role="dialog"
        aria-modal="true"
        aria-labelledby={@title != [] && "#{@id}-title"}
        phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
        phx-key="escape"
        phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
        class="modal-box relative"
      >
        <button
          id={"#{@id}-close"}
          phx-click={JS.exec("data-cancel", to: "##{@id}")}
          type="button"
          class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <h2 :if={@title != []} id={"#{@id}-title"} class="text-lg font-semibold mb-4 pr-8">
          {render_slot(@title)}
        </h2>
        <div id={"#{@id}-content"}>
          {render_slot(@inner_block)}
        </div>
      </.focus_wrap>
    </div>
    """
  end

  @doc "Shows a `<.modal>` by id. See `hide_modal/2`."
  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.push_focus()
    |> JS.add_class("modal-open", to: "##{id}")
    |> JS.focus_first(to: "##{id}-container")
  end

  @doc "Hides a `<.modal>` by id, restoring focus saved by `show_modal/2`."
  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.remove_class("modal-open", to: "##{id}")
    |> JS.pop_focus()
  end

  @doc """
  Renders a copy-to-clipboard button — `SEC-A02`.

  Pure client-side: the value is already on the page, so a round-trip to the
  server would add nothing. `phx-update="ignore"` is set because the
  colocated `.CopyButton` hook mutates its own icon/announce children
  directly — LiveView must never patch over that state mid-confirmation. The
  value itself is read from `data-value` at click time rather than cached in
  `mounted()`, since an ignored subtree does not otherwise pick up a
  re-rendered attribute if the row's value ever changes.

  The hook uses `navigator.clipboard.writeText` where available. Three
  distinct failure paths are handled without ever showing a false success
  (a false confirmation means the user pastes stale clipboard content into a
  config file):

    * `navigator.clipboard` is `undefined` — a non-secure context (plain
      HTTP on a non-localhost origin). Falls back to a hidden `<textarea>` +
      `document.execCommand("copy")`.
    * `writeText` rejects — permission denied, or `NotAllowedError` because
      the document isn't focused. Shown as a failure, not retried through
      the fallback (a rejection here is a real "no", not "API unavailable").
    * The `execCommand` fallback itself returns `false` or throws — also
      shown as a failure.

  Confirmation and failure are both a ~2s icon swap plus an
  `aria-live="polite"` announcement, per `SEC-A02` ("receives brief visual
  confirmation"). Any pending revert timer is cleared before starting a new
  one, so rapid repeat clicks cannot leave the icon stuck, and again in
  `destroyed()` — LiveView reuses DOM nodes across patches, and a leaked
  timer would otherwise fire against a detached element once a row
  re-renders (`SEC-S4`/`SEC-S5`).

  ## Examples

      <.copy_button id="copy-arn" value={@secret.arn} label="Copy ARN" />
  """
  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, default: "Copy"
  attr :class, :any, default: nil

  def copy_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      phx-hook=".CopyButton"
      phx-update="ignore"
      data-value={@value}
      data-label={@label}
      class={["btn btn-ghost btn-sm gap-1", @class]}
      aria-label={@label}
    >
      <span data-copy-icon><.icon name="hero-clipboard-document" class="size-4" /></span>
      <span data-copied-icon class="hidden"><.icon name="hero-check" class="size-4" /></span>
      <span data-copy-failed-icon class="hidden">
        <.icon name="hero-exclamation-triangle" class="size-4" />
      </span>
      <span>{@label}</span>
      <span class="sr-only" aria-live="polite" data-copy-announce></span>
    </button>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyButton">
      export default {
        mounted() {
          this.icon = this.el.querySelector("[data-copy-icon]")
          this.checkIcon = this.el.querySelector("[data-copied-icon]")
          this.failIcon = this.el.querySelector("[data-copy-failed-icon]")
          this.announce = this.el.querySelector("[data-copy-announce]")
          this.el.addEventListener("click", () => this.copy())
        },
        destroyed() {
          clearTimeout(this._resetTimer)
        },
        copy() {
          const value = this.el.dataset.value
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(value)
              .then(() => this.confirm())
              .catch(() => this.fail())
          } else {
            this.fallbackCopy(value)
          }
        },
        fallbackCopy(value) {
          const textarea = document.createElement("textarea")
          textarea.value = value
          textarea.setAttribute("readonly", "")
          textarea.style.position = "fixed"
          textarea.style.opacity = "0"
          document.body.appendChild(textarea)
          textarea.select()
          try {
            document.execCommand("copy") ? this.confirm() : this.fail()
          } catch (_error) {
            this.fail()
          } finally {
            document.body.removeChild(textarea)
          }
        },
        confirm() {
          this.showState(this.checkIcon, `${this.el.dataset.label} copied`)
        },
        fail() {
          this.showState(this.failIcon, `${this.el.dataset.label} failed to copy`)
        },
        showState(activeIcon, message) {
          this.icon.classList.add("hidden")
          this.checkIcon.classList.add("hidden")
          this.failIcon.classList.add("hidden")
          activeIcon.classList.remove("hidden")
          this.announce.textContent = message
          clearTimeout(this._resetTimer)
          this._resetTimer = setTimeout(() => {
            this.icon.classList.remove("hidden")
            this.checkIcon.classList.add("hidden")
            this.failIcon.classList.add("hidden")
            this.announce.textContent = ""
          }, 2000)
        }
      }
    </script>
    """
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(NucleusWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(NucleusWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
