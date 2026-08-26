defmodule NucleusWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use NucleusWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  alias NucleusWeb.SidebarEnvironments

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :environments, Phoenix.LiveView.AsyncResult,
    default: nil,
    doc: """
    async result for the sidebar's Environments section, assigned by
    `NucleusWeb.EnvironmentsHook` at the `live_session` level. `nil` (the
    default) renders the same empty state as a `nil`-vs-loaded distinction
    matters less than never crashing a caller that hasn't wired the hook —
    see `test/support/scope_hook_demo_live.ex` (EN-6), which doesn't. Carries
    every environment the tenant has, archived included —
    `NucleusWeb.SidebarEnvironments.group/1` is what excludes them (`NAV-S1`).
    """

  attr :expanded_categories, MapSet,
    default: MapSet.new(),
    doc: """
    the set of category slugs currently expanded in the sidebar's
    Environments section (`NAV-A05`), assigned by `NucleusWeb.EnvironmentsHook`
    and toggled via its `"toggle-category"` event hook. Defaults to empty —
    every category collapsed — for a caller that hasn't wired the hook.
    """

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div id="shell" data-collapsed="false" class="group relative flex h-screen w-full overflow-hidden">
      <aside
        id="sidebar"
        class="w-64 group-data-[collapsed=true]:w-16 shrink-0 border-r border-base-300 bg-base-100 flex flex-col overflow-y-auto transition-[width] duration-200"
      >
        <div class="h-16 shrink-0 flex items-center justify-start group-data-[collapsed=true]:justify-center px-4 border-b border-base-300">
          <a href="/" class="flex items-center gap-2">
            <img src={~p"/images/logo.svg"} width="28" />
            <span class="font-semibold group-data-[collapsed=true]:hidden">Nucleus</span>
          </a>
        </div>

        <nav class="p-4 flex flex-col gap-6 group-data-[collapsed=true]:items-center group-data-[collapsed=true]:px-2">
          <div>
            <p class="text-xs font-semibold uppercase text-base-content/50 mb-2 px-2 group-data-[collapsed=true]:hidden">
              Tenant
            </p>
            <%!--
              NAV-A03 (active-section highlighting) is out of scope: these
              tenant-wide features don't exist yet, so they render as
              visibly disabled placeholders rather than dead links.
              M2M Clients (M2M-S2, #35) is the first of these three to ship
              a real view — replaced with a working link, not a placeholder.
            --%>
            <ul class="menu menu-sm p-0 group-data-[collapsed=true]:hidden">
              <li>
                <span class="opacity-40 cursor-not-allowed" aria-disabled="true">
                  Applications
                </span>
              </li>
              <li>
                <span class="opacity-40 cursor-not-allowed" aria-disabled="true">
                  Data Export
                </span>
              </li>
              <li>
                <.link navigate={~p"/m2m/clients"}>
                  M2M Clients
                </.link>
              </li>
            </ul>
            <%!--
              Collapsed rail: one icon per section rather than per item —
              expanding is the way back to the individual placeholders.
            --%>
            <button
              type="button"
              class="hidden group-data-[collapsed=true]:flex btn btn-ghost btn-sm btn-square"
              phx-click={toggle_sidebar()}
              title="Tenant"
              aria-label="Tenant"
            >
              <.icon name="hero-squares-2x2" class="size-5" />
            </button>
          </div>

          <div>
            <p class="text-xs font-semibold uppercase text-base-content/50 mb-2 px-2 group-data-[collapsed=true]:hidden">
              Environments
            </p>
            <div class="group-data-[collapsed=true]:hidden">
              <%= if @environments do %>
                <.async_result :let={environments} assign={@environments}>
                  <:loading>
                    <p id="environments-loading" class="text-sm text-base-content/50 px-2">
                      Loading environments…
                    </p>
                  </:loading>
                  <% groups = SidebarEnvironments.group(environments) %>
                  <%= if groups == [] do %>
                    <.empty_state
                      id="environments-empty"
                      icon="hero-server-stack"
                      message="No environments"
                      class="py-4"
                    />
                  <% else %>
                    <ul class="flex flex-col gap-1">
                      <li
                        :for={%{group: group, slug: slug} <- SidebarEnvironments.with_slugs(groups)}
                        id={"environment-category-#{slug}"}
                      >
                        <button
                          type="button"
                          id={"environment-category-#{slug}-toggle"}
                          class="w-full flex items-center justify-between gap-2 px-2 py-1 rounded-md text-sm hover:bg-base-200"
                          phx-click="toggle-category"
                          phx-value-category={slug}
                          aria-expanded={to_string(category_expanded?(@expanded_categories, slug))}
                        >
                          <span class="flex items-center gap-1.5">
                            <.icon
                              name="hero-chevron-right"
                              class={[
                                "size-3.5 transition-transform",
                                category_expanded?(@expanded_categories, slug) &&
                                  "rotate-90"
                              ]}
                            />
                            {category_label(group.category)}
                          </span>
                          <span class="badge badge-sm badge-ghost">{group.count}</span>
                        </button>
                        <ul
                          :if={category_expanded?(@expanded_categories, slug)}
                          id={"environment-category-#{slug}-list"}
                          class="menu menu-sm p-0 pl-4"
                        >
                          <li :for={env <- group.environments}>
                            <.link navigate={~p"/environments/#{env.short_name}"}>
                              {env.label || env.short_name}
                            </.link>
                          </li>
                        </ul>
                      </li>
                    </ul>
                  <% end %>
                </.async_result>
              <% else %>
                <.empty_state
                  id="environments-empty"
                  icon="hero-server-stack"
                  message="No environments"
                  class="py-4"
                />
              <% end %>
            </div>
            <button
              type="button"
              class="hidden group-data-[collapsed=true]:flex btn btn-ghost btn-sm btn-square"
              phx-click={toggle_sidebar()}
              title="Environments"
              aria-label="Environments"
            >
              <.icon name="hero-server-stack" class="size-5" />
            </button>
          </div>
        </nav>
      </aside>

      <%!--
        Sibling of <aside>, not nested inside it: the aside's own
        overflow-y-auto implicitly makes its overflow-x "auto" too (CSS
        overflow spec — one non-visible axis forces the other away from
        "visible"), which clipped this button's protruding half when it
        lived inside the aside. Positioned here, against the shell wrapper,
        it sits fully unclipped on the sidebar/content boundary in both
        states, so the same amount of each chevron is visible whether open
        or collapsed.
      --%>
      <button
        id="sidebar-toggle"
        type="button"
        class="btn btn-circle btn-sm bg-base-100 border border-base-300 shadow-sm absolute left-60 group-data-[collapsed=true]:left-12 top-4 z-10 transition-[left] duration-200"
        phx-click={toggle_sidebar()}
        aria-labelledby="sidebar-toggle-collapse-label sidebar-toggle-expand-label"
      >
        <.icon name="hero-chevron-double-left" class="size-4 group-data-[collapsed=true]:hidden" />
        <.icon
          name="hero-chevron-double-right"
          class="size-4 hidden group-data-[collapsed=true]:inline"
        />
        <%!--
          Two sr-only labels toggled by the same CSS group-data mechanism as
          the icons above, rather than a client-side JS.toggle_attribute
          matching against the attribute's current string value: the
          accessible name changes with `display`, which is guaranteed to
          track `data-collapsed` exactly, instead of independently keeping a
          second piece of toggled state in sync with it.
        --%>
        <span id="sidebar-toggle-collapse-label" class="sr-only group-data-[collapsed=true]:hidden">
          Collapse sidebar
        </span>
        <span
          id="sidebar-toggle-expand-label"
          class="sr-only hidden group-data-[collapsed=true]:inline"
        >
          Expand sidebar
        </span>
      </button>

      <div class="flex-1 flex flex-col overflow-hidden">
        <header class="navbar h-16 border-b border-base-300 shrink-0 px-4">
          <div class="flex-1">
            <span :if={@current_scope} id="tenant-identifier" class="badge badge-outline">
              {@current_scope.tenant}
            </span>
          </div>
          <div class="flex-none flex items-center gap-2">
            <.theme_toggle />

            <div :if={@current_scope} id="user-menu" class="dropdown dropdown-end">
              <button
                type="button"
                class="btn btn-ghost btn-circle"
                phx-click={JS.toggle(to: "#user-menu-panel")}
                aria-label={gettext("User menu")}
              >
                <.icon name="hero-user-circle" class="size-6" />
              </button>
              <div
                id="user-menu-panel"
                class="dropdown-content menu bg-base-100 rounded-box shadow-lg w-64 p-4 mt-2 z-10 hidden"
                phx-click-away={JS.hide(to: "#user-menu-panel")}
                phx-window-keydown={JS.hide(to: "#user-menu-panel")}
                phx-key="Escape"
              >
                <p class="font-semibold break-all text-sm">{@current_scope.user.email}</p>
                <div class="mt-3">
                  <p class="text-xs uppercase text-base-content/50 mb-1">Scopes</p>
                  <%= if @current_scope.scopes == [] do %>
                    <p class="text-sm text-base-content/60">No scopes granted</p>
                  <% else %>
                    <ul class="flex flex-wrap gap-1">
                      <li :for={scope <- @current_scope.scopes}>
                        <.badge>{scope}</.badge>
                      </li>
                    </ul>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        </header>

        <main class="flex-1 overflow-y-auto p-6">
          {render_slot(@inner_block)}
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Toggles the sidebar's collapsed state — `#shell`'s `data-collapsed`
  attribute.

  Shared by the main toggle button and both collapsed-rail icons (Tenant,
  Environments) so all three ways of reopening the sidebar stay in sync by
  construction. `#sidebar-toggle`'s accessible name and icon both track
  `data-collapsed` declaratively via CSS (`group-data-[collapsed=true]:*`),
  not a second piece of client-side state kept in sync by hand here.
  """
  def toggle_sidebar(js \\ %JS{}) do
    JS.toggle_attribute(js, {"data-collapsed", "true"}, to: "#shell")
  end

  # Sidebar Environments category disclosure (`NAV-A04`/`NAV-A05`) — the
  # human-facing label and whether the category is currently expanded, both
  # derived from a `NucleusWeb.SidebarEnvironments.group/1` entry's
  # `:category` field (either a category name or `:uncategorized`). The
  # DOM-safe, collision-disambiguated id itself comes from
  # `NucleusWeb.SidebarEnvironments.with_slugs/1`, not from `:category`
  # directly — see that function's moduledoc for why a category name alone
  # is not a safe, unique DOM id.

  defp category_label(:uncategorized), do: "Uncategorized"
  defp category_label(category) when is_binary(category), do: category

  defp category_expanded?(expanded_categories, slug) do
    MapSet.member?(expanded_categories, slug)
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
