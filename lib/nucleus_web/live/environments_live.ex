defmodule NucleusWeb.EnvironmentsLive do
  @moduledoc """
  An environment's detail view — `ENV-A02`–`ENV-A07`.

  Single module, no index/show split: there is no `/environments` list route
  (the sidebar is the index — `Environments.md`'s "Out of scope" section),
  so there is nothing for a second module to be reached from except this
  one's own error states.

  ## Validated in `handle_params/3`, not `mount/3`

  Mirrors `NucleusWeb.SecretsLive` and ADR-0009: the environment name comes
  from the URL, and a `<.link patch={...}>` between two environments does not
  remount the LiveView. `handle_params/3` runs on every patch; `mount/3` does
  not, so a check placed there would let a user patch from a validated
  environment straight into an unvalidated one.

  ## `Nucleus.Environments.fetch/2` directly, no proxy route

  `Environments.md`'s API contract names `GET /api/proxy/environments`, but
  that line is advisory — `PRX-A01`–`A07` is a separate, unstarted feature,
  and `Nucleus.Environments.fetch/2` already exists in-process, the same
  boundary `SecretsLive` calls. Nothing here touches `router.ex`'s `:api`
  pipeline.

  ## Every outcome gets its own assign and DOM id

  `Environments.fetch/2` only ever tags an error `boundary: :tenant_api`
  (the one boundary it touches), but this `case` still matches every
  `Nucleus.Backend.Error.kinds/0` value so the view never crashes if that
  ever changes:

  | Outcome | `:environment_status` | DOM id |
  |---|---|---|
  | `{:ok, env}` | `:ok` | `#environment-detail` |
  | `kind: :invalid` | `:invalid` | `#environment-invalid` |
  | `kind: :not_found` | `:not_found` | `#environment-not-found` (`ENV-A05`) |
  | `kind: :unavailable` | `:unavailable` | `#environment-unavailable` (the `ENV-D1` amendment — distinct from not-found) |
  | `kind: :auth_expired` | `:auth_expired` | `#environment-auth-expired` (placeholder copy; `SEC-S7`/#15 owns real retry semantics) |
  | anything else (`:already_exists`, `:not_configured`) | `:unavailable` | `#environment-unavailable` |

  `:not_configured` collapsing to `:unavailable` happens one layer down, in
  `Nucleus.Environments.fetch/2` itself (`SEC-A17`) — it never reaches this
  `case` as its own kind. It is listed above only because the catch-all
  branch must account for every value `kinds/0` could carry.

  Every branch keeps `<Layouts.app>` (and its sidebar) intact, so a crashed
  or dead-ended LiveView is never how any of these render.

  ## Read-only — `ENV-A07`

  Environment metadata is owned by the tenant's own backing systems, not by
  Nucleus. There is no form, no button with a write `phx-click`, and no
  delete affordance anywhere in this module's template — the absence itself
  is the deliverable.

  ## The IRI and the accent color are both validated before use

  `Nucleus.TenantApi.Environment.from_api/1` only validates that `iri` is a
  string, not that it is a safe URI scheme — interpolating it directly into
  an `href` would let a tenant's own API hand back a `javascript:` scheme.
  `iri_href/1` gates it against an `http`/`https`-with-host allowlist before
  it is ever used as a link target; only then does the "open in a new tab"
  button (`#open-iri`) render at all, and it always pairs
  `target="_blank"` with `rel="noopener noreferrer"` so the new tab can't
  reach back into this one. The raw IRI is always shown as HEEx-escaped
  text next to it regardless of whether it passed validation — the text
  never depends on the link.

  `accent_color` has the same problem in a different attribute: an
  unvalidated string interpolated into a `style` attribute is the same
  injection class as an unvalidated `href`. `valid_hex_color?/1` gates it
  against a hex-color allowlist before it ever reaches a `style=` value; a
  non-conforming value falls back to a neutral swatch, with the raw string
  still shown as escaped text so nothing about the environment is hidden,
  only untrusted as a style input.

  ## Archived environments render fully — `ENV-A06`

  `Environments.fetch/2` resolves archived environments the same as active
  ones (`Nucleus.Environments`'s own moduledoc) — this module does not filter
  them a second time. Only `NucleusWeb.EnvironmentsHook` (the sidebar) hides
  archived environments from navigation; a direct URL always reaches here.
  """

  use NucleusWeb, :live_view

  alias Nucleus.Backend.Error
  alias Nucleus.Environments

  @hex_color ~r/\A#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\z/
  @safe_iri_schemes ~w(http https)

  @impl Phoenix.LiveView
  def handle_params(%{"environment" => environment}, _uri, socket) do
    {:noreply, fetch_environment(socket, environment)}
  end

  defp fetch_environment(socket, environment) do
    socket = assign(socket, :environment_name, environment)

    case Environments.fetch(environment, socket.assigns.current_scope.token) do
      {:ok, env} ->
        assign(socket, environment_status: :ok, environment: env)

      {:error, %Error{kind: :invalid, boundary: :tenant_api}} ->
        assign(socket, environment_status: :invalid, environment: nil)

      {:error, %Error{kind: :not_found, boundary: :tenant_api}} ->
        assign(socket, environment_status: :not_found, environment: nil)

      {:error, %Error{kind: :unavailable, boundary: :tenant_api}} ->
        assign(socket, environment_status: :unavailable, environment: nil)

      {:error, %Error{kind: :auth_expired}} ->
        assign(socket, environment_status: :auth_expired, environment: nil)

      {:error, %Error{}} ->
        assign(socket, environment_status: :unavailable, environment: nil)
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      environments={@environments}
      expanded_categories={@expanded_categories}
    >
      <.empty_state
        :if={@environment_status == :invalid}
        id="environment-invalid"
        icon="hero-shield-exclamation"
        message="This is not a valid environment name."
      />
      <.empty_state
        :if={@environment_status == :not_found}
        id="environment-not-found"
        icon="hero-question-mark-circle"
        message={"No environment named \"#{@environment_name}\" was found for this tenant."}
      />
      <.empty_state
        :if={@environment_status == :unavailable}
        id="environment-unavailable"
        icon="hero-exclamation-triangle"
        message="Can't verify this environment right now. Try again shortly."
      />
      <.empty_state
        :if={@environment_status == :auth_expired}
        id="environment-auth-expired"
        icon="hero-lock-closed"
        message="This environment can't be reached right now."
      />

      <div :if={@environment_status == :ok} id="environment-detail">
        <div class="flex items-center justify-between gap-4 pb-4">
          <h1 class="text-lg font-semibold">{@environment.label || @environment.short_name}</h1>
          <.link
            id="manage-secrets-link"
            navigate={~p"/environments/#{@environment.short_name}/secrets"}
            class="btn btn-primary"
          >
            Manage Secrets
          </.link>
        </div>

        <.description_list>
          <:item title="Short name">{@environment.short_name}</:item>
          <:item title="Label">{@environment.label || @environment.short_name}</:item>
          <:item title="Status">
            <.badge variant={if @environment.archived?, do: "neutral", else: "success"}>
              {if @environment.archived?, do: "Archived", else: "Active"}
            </.badge>
          </:item>
          <:item :if={@environment.iri} title="IRI">
            <div class="flex items-center gap-1">
              <span class="break-all">{@environment.iri}</span>
              <.copy_button id="copy-iri" value={@environment.iri} label="Copy IRI" />
              <span
                :if={iri_href(@environment.iri)}
                class="tooltip"
                data-tip="Open IRI in new tab"
              >
                <.link
                  id="open-iri"
                  href={iri_href(@environment.iri)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn btn-ghost btn-sm btn-square"
                  aria-label="Open IRI in new tab"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-4" />
                </.link>
              </span>
            </div>
          </:item>
          <:item title="Accent color">
            <div class="flex items-center gap-2">
              <span
                :if={@environment.accent_color}
                class="inline-block size-4 rounded-full border border-base-300"
                style={accent_style(@environment.accent_color)}
              />
              <span :if={!@environment.accent_color} class="text-base-content/50">None</span>
              <span :if={@environment.accent_color}>{@environment.accent_color}</span>
            </div>
          </:item>
          <:item title="Categories">
            {if @environment.categories == [],
              do: "None",
              else: Enum.join(@environment.categories, ", ")}
          </:item>
          <:item :if={@environment.description} title="Description">
            <p id="environment-description">{@environment.description}</p>
          </:item>
        </.description_list>
      </div>
    </Layouts.app>
    """
  end

  # A validated `style` value, or `nil` when `color` fails the hex allowlist
  # — the swatch renders neutral and the raw string is still shown as
  # escaped text alongside it (see the moduledoc, "The IRI and the accent
  # color are both validated before use").
  defp accent_style(color) do
    if valid_hex_color?(color), do: "background-color: #{color};", else: nil
  end

  defp valid_hex_color?(color) when is_binary(color), do: Regex.match?(@hex_color, color)
  defp valid_hex_color?(_color), do: false

  # `iri`, or `nil` when it fails the `http`/`https`-with-host allowlist —
  # the "open in a new tab" button only renders when this returns a value
  # (see the moduledoc, "The IRI and the accent color are both validated
  # before use"). The raw string is always shown as escaped text regardless
  # of this check.
  defp iri_href(iri) when is_binary(iri) do
    case URI.parse(iri) do
      %URI{scheme: scheme, host: host}
      when scheme in @safe_iri_schemes and is_binary(host) and host != "" ->
        iri

      _other ->
        nil
    end
  end

  defp iri_href(_iri), do: nil
end
