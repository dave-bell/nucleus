defmodule NucleusWeb.SecretsLiveTest do
  # `force_error/2` (`Nucleus.BackendCase`) mutates node-global state.
  use NucleusWeb.LiveCase, async: false

  alias Nucleus.Backend.Error
  alias Nucleus.Secrets

  defmodule FailingSecretsStore do
    @moduledoc """
    A `Nucleus.Secrets.Store` implementation that always fails `list_secrets/1`
    and `get_secret/2` with a controllable `Nucleus.Backend.Error`.

    `Nucleus.Backend.Faults`' `LOCAL_FORCE_ERROR` is node-global and checked by
    `Nucleus.TenantApi.Local` too — since `Nucleus.Secrets.list/2` and
    `Nucleus.Secrets.reveal/3` both gate through `Nucleus.Environments.fetch/2`
    first, a global fault is always caught there (`boundary: :tenant_api`) and
    the store is never reached. Swapping the `:secrets` boundary's
    implementation instead, the same technique
    `test/nucleus/environments_test.exs`'s `ExplodingTenantApi` uses, is the
    only way to exercise a `boundary: :secrets` failure from this LiveView —
    for both listing (`SEC-A17`) and a failed reveal (`SEC-A05`).
    """
    @behaviour Nucleus.Secrets.Store

    @impl Nucleus.Secrets.Store
    def list_secrets(_environment) do
      {:error, Error.new(:unavailable, :secrets, "forced for test", %{})}
    end

    @impl Nucleus.Secrets.Store
    def get_secret(_environment, _key) do
      {:error, Error.new(:unavailable, :secrets, "forced for test", %{})}
    end

    @impl Nucleus.Secrets.Store
    def create_secret(_environment, _key, _value), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def update_secret(_environment, _key, _value), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def locate_secret(_environment, _key), do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def list_environments, do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def list_all_secrets, do: raise("should not be called")

    @impl Nucleus.Secrets.Store
    def health_check, do: raise("should not be called")
  end

  defp use_failing_secrets_store do
    original = Application.get_env(:nucleus, :backends, [])
    on_exit(fn -> Application.put_env(:nucleus, :backends, original) end)

    Application.put_env(
      :nucleus,
      :backends,
      Keyword.put(original, :secrets, FailingSecretsStore)
    )
  end

  describe "SEC-A01 — list secrets for an environment" do
    @tag action: "SEC-A01"
    test "every seeded key under prod has a row", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      assert has_element?(view, "#secrets-table")
      assert has_element?(view, "[data-key=\"DATABASE_URL\"]")
      assert has_element?(view, "[data-key=\"STRIPE_API_KEY\"]")
      assert has_element?(view, "[data-key=\"JWT_SIGNING_KEY\"]")
    end

    @tag action: "SEC-A01"
    test "each row contains the full path and the full ARN", %{conn: conn} do
      assert {:ok, refs} = Secrets.list("prod", %Nucleus.Scope{})
      assert {:ok, _view, html} = live_secrets(conn, "prod")

      for ref <- refs do
        assert html =~ ref.path
        assert html =~ ref.arn
      end
    end

    @tag action: "SEC-A01"
    test "no seeded secret value appears anywhere in the rendered HTML", %{conn: conn} do
      assert {:ok, %{value: db_value}} = Nucleus.Secrets.Store.get_secret("prod", "DATABASE_URL")

      assert {:ok, %{value: stripe_value}} =
               Nucleus.Secrets.Store.get_secret("prod", "STRIPE_API_KEY")

      assert {:ok, %{value: jwt_value}} =
               Nucleus.Secrets.Store.get_secret("prod", "JWT_SIGNING_KEY")

      assert {:ok, _view, html} = live_secrets(conn, "prod")

      refute html =~ db_value
      refute html =~ stripe_value
      refute html =~ jwt_value
    end

    @tag action: "SEC-A01"
    test "there is no value column at all — no plaintext cell and no mask", %{conn: conn} do
      assert {:ok, _view, html} = live_secrets(conn, "prod")
      doc = LazyHTML.from_document(html)

      headers =
        doc
        |> LazyHTML.query("#secrets-table thead th")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert headers == ["Key", "Path", "ARN", "Last modified", "Actions"]

      # One cell per header, so there is no orphaned value cell either.
      assert doc |> LazyHTML.query("[data-key=\"DATABASE_URL\"] td") |> Enum.count() == 5

      # A mask is a promise that nothing leaked, and one that has to be
      # careful not to encode the real length. There is no mask because
      # there is no column to put one in.
      refute html =~ "••••"
    end

    @tag action: "SEC-A01"
    test "path and ARN each carry a tooltip holding the full, untruncated value", %{conn: conn} do
      assert {:ok, refs} = Secrets.list("prod", %Nucleus.Scope{})
      assert {:ok, _view, html} = live_secrets(conn, "prod")
      doc = LazyHTML.from_document(html)

      for ref <- refs do
        row = "[data-key=\"#{ref.key}\"]"

        tips = doc |> LazyHTML.query("#{row} [data-tip]") |> LazyHTML.attribute("data-tip")

        assert ref.path in tips
        assert ref.arn in tips
      end

      # `truncate` includes `overflow: hidden`, and daisyUI renders the
      # tooltip as a pseudo-element *inside* the `.tooltip` element — sharing
      # one span would clip the tooltip. The wrapper must not truncate.
      assert Enum.empty?(LazyHTML.query(doc, ".tooltip.truncate"))
      refute Enum.empty?(LazyHTML.query(doc, ".tooltip > .truncate"))
    end

    @tag action: "SEC-A01"
    test "the reveal control is present per row", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      assert has_element?(view, "button[phx-value-key=\"DATABASE_URL\"]")
      assert has_element?(view, "button[phx-value-key=\"STRIPE_API_KEY\"]")
      assert has_element?(view, "button[phx-value-key=\"JWT_SIGNING_KEY\"]")
    end

    @tag action: "SEC-A01"
    test "the reveal control is its label alone — no icon", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      button = view |> element("#reveal-#{row_id}") |> render() |> LazyHTML.from_fragment()

      assert button |> LazyHTML.text() |> String.trim() == "View"
      assert Enum.empty?(LazyHTML.query(button, "[class*=\"hero-\"]"))
    end

    test "ordering is stable across two mounts", %{conn: conn} do
      assert {:ok, _view1, html1} = live_secrets(conn, "prod")
      assert {:ok, _view2, html2} = live_secrets(conn, "prod")

      assert {:ok, refs} = Secrets.list("prod", %Nucleus.Scope{})
      keys = Enum.map(refs, & &1.key)

      positions1 = Enum.map(keys, &key_position(html1, &1))
      positions2 = Enum.map(keys, &key_position(html2, &1))

      assert positions1 == Enum.sort(positions1)
      assert positions1 == positions2
    end
  end

  describe "SEC-A02 — copy a secret's path or ARN" do
    # `Phoenix.LiveViewTest` cannot execute JS hooks (`docs/adr/0008-test-strategy.md`)
    # — the actual `navigator.clipboard.writeText` call, the confirmation
    # icon swap/revert, the non-secure-context fallback, and the failure
    # indication are recorded as browser gaps, never claimed here. These
    # tests prove only the wiring the hook depends on: the button is
    # present per row, carries the colocated hook, and carries the full,
    # untruncated value at click time — which is why they carry
    # `@tag action: "SEC-A02"` while the unverified behaviours below do not.

    @tag action: "SEC-A02"
    test "each row carries a copy button for its path and its ARN", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      for key <- ["DATABASE_URL", "STRIPE_API_KEY", "JWT_SIGNING_KEY"] do
        row = view |> element("[data-key=\"#{key}\"]") |> render()
        doc = LazyHTML.from_fragment(row)

        refute Enum.empty?(LazyHTML.query(doc, "[id^=\"copy-path-\"]"))
        refute Enum.empty?(LazyHTML.query(doc, "[id^=\"copy-arn-\"]"))
      end
    end

    @tag action: "SEC-A02"
    test "each copy button carries the colocated hook", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      row = view |> element("[data-key=\"DATABASE_URL\"]") |> render()
      doc = LazyHTML.from_fragment(row)

      path_button = LazyHTML.query(doc, "[id^=\"copy-path-\"]")
      arn_button = LazyHTML.query(doc, "[id^=\"copy-arn-\"]")

      assert [hook] = LazyHTML.attribute(path_button, "phx-hook")
      assert hook =~ "CopyButton"
      assert [hook] = LazyHTML.attribute(arn_button, "phx-hook")
      assert hook =~ "CopyButton"
    end

    @tag action: "SEC-A02"
    test "data-value holds the full, untruncated path and ARN — the truncation guard", %{
      conn: conn
    } do
      assert {:ok, refs} = Secrets.list("prod", %Nucleus.Scope{})
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      for ref <- refs do
        row = view |> element("[data-key=\"#{ref.key}\"]") |> render()
        doc = LazyHTML.from_fragment(row)

        path_button = LazyHTML.query(doc, "[id^=\"copy-path-\"]")
        arn_button = LazyHTML.query(doc, "[id^=\"copy-arn-\"]")

        # ARNs here run well past `max-w-xs`'s truncation width — the exact
        # equality below fails if the source were ever the truncated span
        # rather than the stream item's own untruncated field.
        assert LazyHTML.attribute(path_button, "data-value") == [ref.path]
        assert LazyHTML.attribute(arn_button, "data-value") == [ref.arn]
      end
    end

    @tag action: "SEC-A02"
    test "copy button ids are unique across rows", %{conn: conn} do
      assert {:ok, _view, html} = live_secrets(conn, "prod")
      doc = LazyHTML.from_fragment(html)

      path_ids = LazyHTML.query(doc, "[id^=\"copy-path-\"]") |> LazyHTML.attribute("id")
      arn_ids = LazyHTML.query(doc, "[id^=\"copy-arn-\"]") |> LazyHTML.attribute("id")

      assert length(path_ids) == 3
      assert length(arn_ids) == 3
      assert Enum.uniq(path_ids ++ arn_ids) == path_ids ++ arn_ids
    end

    @tag action: "SEC-A02"
    test "aria-label distinguishes copying a path from copying an ARN", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      row = view |> element("[data-key=\"DATABASE_URL\"]") |> render()
      doc = LazyHTML.from_fragment(row)

      path_button = LazyHTML.query(doc, "[id^=\"copy-path-\"]")
      arn_button = LazyHTML.query(doc, "[id^=\"copy-arn-\"]")

      assert LazyHTML.attribute(path_button, "aria-label") == ["Copy path"]
      assert LazyHTML.attribute(arn_button, "aria-label") == ["Copy ARN"]
    end

    @tag action: "SEC-A02"
    test "in-row copy buttons are icon-only — the label is a tooltip, not layout width", %{
      conn: conn
    } do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      row = view |> element("[data-key=\"DATABASE_URL\"]") |> render()
      doc = LazyHTML.from_fragment(row)

      # The label reaches a sighted user through daisyUI's `.tooltip` +
      # `data-tip` (a CSS pseudo-element), so it costs no horizontal space.
      refute Enum.empty?(LazyHTML.query(doc, ".tooltip[data-tip=\"Copy path\"]"))
      refute Enum.empty?(LazyHTML.query(doc, ".tooltip[data-tip=\"Copy ARN\"]"))

      # ...and is not a text node inside the button, which is what was
      # taking the space.
      path_text = doc |> LazyHTML.query("[id^=\"copy-path-\"]") |> LazyHTML.text()
      refute path_text =~ "Copy path"
    end

    @tag action: "SEC-A02"
    test "phx-update=\"ignore\" is present so LiveView never patches over confirmation state",
         %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      row = view |> element("[data-key=\"DATABASE_URL\"]") |> render()
      doc = LazyHTML.from_fragment(row)

      path_button = LazyHTML.query(doc, "[id^=\"copy-path-\"]")
      arn_button = LazyHTML.query(doc, "[id^=\"copy-arn-\"]")

      assert LazyHTML.attribute(path_button, "phx-update") == ["ignore"]
      assert LazyHTML.attribute(arn_button, "phx-update") == ["ignore"]
    end

    @tag action: "SEC-A02"
    test "an aria-live region exists for the copy confirmation announcement", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      row = view |> element("[data-key=\"DATABASE_URL\"]") |> render()
      doc = LazyHTML.from_fragment(row)

      refute Enum.empty?(LazyHTML.query(doc, "[aria-live=\"polite\"]"))
    end

    @tag action: "SEC-A02"
    test "copy buttons have no phx-click — copying is client-side only, no server round-trip",
         %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      refute has_element?(view, "#flash-info")
      refute has_element?(view, "#flash-error")

      row = view |> element("[data-key=\"DATABASE_URL\"]") |> render()
      doc = LazyHTML.from_fragment(row)

      path_button = LazyHTML.query(doc, "[id^=\"copy-path-\"]")
      arn_button = LazyHTML.query(doc, "[id^=\"copy-arn-\"]")

      assert LazyHTML.attribute(path_button, "phx-click") == []
      assert LazyHTML.attribute(arn_button, "phx-click") == []
      assert_no_audit_event(:secret_created)
      assert_no_audit_event(:secret_viewed)
      assert_no_audit_event(:secret_updated)
    end
  end

  defmodule CopyButtonBrowserGaps do
    @moduledoc """
    `SEC-A02` behaviour `Phoenix.LiveViewTest` structurally cannot execute —
    there is no browser here to run `navigator.clipboard`, no real click
    event dispatch, and no wall clock for a `setTimeout` revert
    (`docs/adr/0008-test-strategy.md`). Skipped unconditionally, not by
    default-exclude tag, so `mix test` output always shows these as skipped
    rather than silently passing zero assertions — and so they are
    discoverable in the suite itself, not only in `living-notes.md`, once a
    driver (Wallaby, deferred to `EN-8`) is adopted.

    None of these carry `@tag action: "SEC-A02"` — see the wiring-only
    describe block above for what is actually proven today.
    """

    use ExUnit.Case, async: true

    @moduletag :browser
    @moduletag skip: "no browser driver in this repo — see docs/adr/0008-test-strategy.md"

    test "navigator.clipboard.writeText is called with the button's full, untruncated value" do
    end

    test "on success, the icon swaps to a check and reverts to the clipboard icon after ~2s" do
    end

    test "over a non-secure context (no navigator.clipboard), the execCommand fallback copies" do
    end

    test "a failed copy (permission denied, unfocused document) shows failure, never success" do
    end
  end

  describe "SEC-A14 — empty state for an environment with no secrets" do
    @tag action: "SEC-A14"
    test "renders #secrets-empty, no #secrets-table", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "sandbox")

      assert has_element?(view, "#secrets-empty")
      refute has_element?(view, "#secrets-table")
    end

    @tag action: "SEC-A14"
    test "#secrets-create-button is present in the empty state", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "sandbox")

      assert has_element?(view, "#secrets-create-button")
    end

    @tag action: "SEC-A14"
    test "#secrets-create-button is also present in the populated state", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      assert has_element?(view, "#secrets-table")
      assert has_element?(view, "#secrets-create-button")
    end
  end

  describe "store unavailable (boundary: :secrets)" do
    test "renders #secrets-unavailable, shell intact, no crash", %{conn: conn} do
      use_failing_secrets_store()

      assert {:ok, view, _html} = live_secrets(conn, "prod")

      assert has_element?(view, "#secrets-unavailable")
      assert has_element?(view, "#tenant-identifier")
      refute has_element?(view, "#secrets-table")
      refute has_element?(view, "#secrets-validation-unavailable")
    end
  end

  describe "placeholder handlers do not crash the LiveView" do
    test "clicking the create button does not crash", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      view |> element("#secrets-create-button") |> render_click()

      assert has_element?(view, "#secrets-table")
    end
  end

  describe "SEC-A03 — reveal a secret's value" do
    @tag action: "SEC-A03"
    test "opens a modal holding the plaintext and its own copy affordance", %{conn: conn} do
      assert {:ok, %{value: db_value}} = Secrets.Store.get_secret("prod", "DATABASE_URL")
      assert {:ok, view, html} = live_secrets(conn, "prod")
      refute html =~ db_value
      refute has_element?(view, "#secret-modal")

      row_id = row_id(view, "DATABASE_URL")

      html = view |> element("#reveal-#{row_id}") |> render_click()

      assert html =~ db_value
      assert has_element?(view, "#secret-modal")
      assert has_element?(view, "#secret-modal-value")
      assert has_element?(view, "#secret-modal-copy")
    end

    @tag action: "SEC-A03"
    test "the modal's copy button carries the full plaintext as its data-value", %{conn: conn} do
      assert {:ok, %{value: db_value}} = Secrets.Store.get_secret("prod", "DATABASE_URL")
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      view |> element("#reveal-#{row_id}") |> render_click()

      doc = view |> render() |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("#secret-modal-copy") |> LazyHTML.attribute("data-value") ==
               [db_value]
    end

    @tag action: "SEC-A03"
    test "the modal is titled with the secret's key", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      view |> element("#reveal-#{row_id}") |> render_click()

      assert view |> element("#secret-modal-title") |> render() =~ "DATABASE_URL"
    end

    @tag action: "SEC-A03"
    test "the modal's copy button is a label, sized to match Close, and carries no icon", %{
      conn: conn
    } do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      view |> element("#reveal-#{row_id}") |> render_click()
      doc = view |> render() |> LazyHTML.from_fragment()

      copy = LazyHTML.query(doc, "#secret-modal-copy")
      assert copy |> LazyHTML.text() =~ "Copy value"
      assert Enum.empty?(LazyHTML.query(doc, "#secret-modal-copy [class*=\"hero-\"]"))
      assert Enum.empty?(LazyHTML.query(doc, "#secret-modal-copy [data-tip]"))

      # Both action-row buttons are the same daisyUI size, so they line up.
      assert [copy_class] = LazyHTML.attribute(copy, "class")

      assert [close_class] =
               doc |> LazyHTML.query("#secret-modal-dismiss") |> LazyHTML.attribute("class")

      refute copy_class =~ "btn-sm"
      refute close_class =~ "btn-sm"
    end

    @tag action: "SEC-A03"
    test "only the revealed secret's value appears — other seeded values stay absent", %{
      conn: conn
    } do
      assert {:ok, %{value: stripe_value}} = Secrets.Store.get_secret("prod", "STRIPE_API_KEY")
      assert {:ok, %{value: jwt_value}} = Secrets.Store.get_secret("prod", "JWT_SIGNING_KEY")

      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      html = view |> element("#reveal-#{row_id}") |> render_click()

      refute html =~ stripe_value
      refute html =~ jwt_value
    end

    @tag action: "SEC-A03"
    test "emits a secret_viewed audit event", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      view |> element("#reveal-#{row_id}") |> render_click()

      assert_audit_event(:secret_viewed, tenant: "local")
    end

    test "revealing a second secret replaces the first in the modal", %{conn: conn} do
      assert {:ok, %{value: db_value}} = Secrets.Store.get_secret("prod", "DATABASE_URL")
      assert {:ok, %{value: stripe_value}} = Secrets.Store.get_secret("prod", "STRIPE_API_KEY")

      assert {:ok, view, _html} = live_secrets(conn, "prod")

      view |> element("#reveal-#{row_id(view, "DATABASE_URL")}") |> render_click()
      html = view |> element("#reveal-#{row_id(view, "STRIPE_API_KEY")}") |> render_click()

      assert html =~ stripe_value
      refute html =~ db_value
    end
  end

  describe "SEC-A04 — hide a revealed secret's value" do
    # The modal offers four dismissal routes. Only the Close button pushes a
    # plain event a `render_click/1` can drive; the X, Escape, and a backdrop
    # click all run a `Phoenix.LiveView.JS` command chain through the
    # component's `data-cancel` attribute, which `Phoenix.LiveViewTest` does
    # not execute (`docs/adr/0008-test-strategy.md`). Those three are asserted
    # as wiring here and recorded as browser gaps below — the outcome they
    # share with Close (the plaintext leaves the DOM) is proven through Close.

    @tag action: "SEC-A04"
    test "the Close button removes the modal and the plaintext with it", %{conn: conn} do
      assert {:ok, %{value: db_value}} = Secrets.Store.get_secret("prod", "DATABASE_URL")
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      assert view |> element("#reveal-#{row_id}") |> render_click() =~ db_value

      html = view |> element("#secret-modal-dismiss") |> render_click()

      refute html =~ db_value
      refute has_element?(view, "#secret-modal")
      refute has_element?(view, "#secret-modal-value")
      assert has_element?(view, "#secrets-table")
    end

    @tag action: "SEC-A04"
    test "hiding emits no audit event", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      view |> element("#reveal-#{row_id}") |> render_click()
      assert_audit_event(:secret_viewed)

      view |> element("#secret-modal-dismiss") |> render_click()

      assert length(audit_events()) == 1
    end

    @tag action: "SEC-A04"
    test "reveal -> hide -> reveal works and emits two events", %{conn: conn} do
      assert {:ok, %{value: db_value}} = Secrets.Store.get_secret("prod", "DATABASE_URL")
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      assert view |> element("#reveal-#{row_id}") |> render_click() =~ db_value
      refute view |> element("#secret-modal-dismiss") |> render_click() =~ db_value
      assert view |> element("#reveal-#{row_id}") |> render_click() =~ db_value

      events = Enum.filter(audit_events(), &(&1.event == :secret_viewed))
      assert length(events) == 2
    end

    test "the X, Escape, and a backdrop click are all wired to the same hide push", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      view |> element("#reveal-#{row_id}") |> render_click()
      doc = view |> render() |> LazyHTML.from_fragment()

      # `on_cancel` is the one place the hide push is declared; the X,
      # Escape, and the backdrop each `JS.exec` this attribute.
      assert [cancel] =
               doc |> LazyHTML.query("#secret-modal") |> LazyHTML.attribute("data-cancel")

      assert cancel =~ "hide"

      container = LazyHTML.query(doc, "#secret-modal-container")
      assert LazyHTML.attribute(container, "phx-key") == ["escape"]
      assert LazyHTML.attribute(container, "phx-window-keydown") != []
      assert LazyHTML.attribute(container, "phx-click-away") != []
      assert LazyHTML.attribute(container, "role") == ["dialog"]
      assert LazyHTML.attribute(container, "aria-modal") == ["true"]

      assert doc |> LazyHTML.query("#secret-modal-close") |> LazyHTML.attribute("phx-click") != []
    end

    # A modal that only exists while open is inserted already-open, which is
    # `show={true}` compiling to `phx-mounted`. Drop it and every other test
    # here still passes — they assert the plaintext is in the payload, not that
    # anything is painted — while the user clicks View and sees nothing.
    test "the modal is inserted already-open, via phx-mounted", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      view |> element("#reveal-#{row_id}") |> render_click()
      doc = view |> render() |> LazyHTML.from_fragment()

      assert [mounted] =
               doc |> LazyHTML.query("#secret-modal") |> LazyHTML.attribute("phx-mounted")

      assert mounted =~ "modal-open"
    end

    test "the value region is focusable, so a value taller than the modal can be scrolled", %{
      conn: conn
    } do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      view |> element("#reveal-#{row_id}") |> render_click()

      region =
        view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("#secret-modal-value")

      assert LazyHTML.attribute(region, "tabindex") == ["0"]
      assert LazyHTML.attribute(region, "role") == ["region"]
      assert LazyHTML.attribute(region, "aria-label") != []
    end

    test "the hide event is idempotent — a second dismissal cannot crash the view", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      render_click(view, "hide", %{})
      render_click(view, "hide", %{})

      assert has_element?(view, "#secrets-table")
      refute has_element?(view, "#secret-modal")
    end
  end

  defmodule SecretRevealModalBrowserGaps do
    @moduledoc """
    `SEC-A04` dismissal behaviour `Phoenix.LiveViewTest` structurally cannot
    execute. Escape and a backdrop click reach the server only by running the
    `Phoenix.LiveView.JS` chain in `data-cancel`, which needs a real key
    event, a real click outside the `.modal-box`, and a client to interpret
    the command list — none of which exist here
    (`docs/adr/0008-test-strategy.md`). Focus restoration is the same story:
    `JS.push_focus/1`/`JS.pop_focus/1` are client-side.

    Skipped unconditionally rather than by default-exclude tag, so `mix test`
    always reports them as skipped instead of silently passing zero
    assertions, and so the gap is discoverable in the suite itself and not
    only in `living-notes.md`, once a driver (Wallaby, deferred to `EN-8`) is
    adopted. None carry `@tag action:` — the describe block above records what
    is actually proven.
    """

    use ExUnit.Case, async: true

    @moduletag :browser
    @moduletag skip: "no browser driver in this repo — see docs/adr/0008-test-strategy.md"

    test "pressing Escape while the modal is open removes it and its plaintext" do
    end

    test "clicking the backdrop outside the modal box removes it and its plaintext" do
    end

    test "the X in the top right removes the modal and its plaintext" do
    end

    test "focus moves into the modal on open and returns to the row's View button on dismissal" do
    end

    test "Tab is trapped inside the modal while it is open" do
    end
  end

  describe "SEC-A05 — handle a failed reveal" do
    @tag action: "SEC-A05"
    test "store forced :unavailable: error flash shown, no modal opens, view alive",
         %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      use_failing_secrets_store()

      html = view |> element("#reveal-#{row_id}") |> render_click()

      assert has_element?(view, "#flash-error")
      # A failed reveal must not open an empty dialog — the error belongs on
      # the page the user is already looking at.
      refute has_element?(view, "#secret-modal")
      refute has_element?(view, "#secret-modal-value")
      assert html =~ "View"
      assert has_element?(view, "#secrets-table")
    end

    @tag action: "SEC-A05"
    test "store forced :not_found: distinct error copy", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      render_click(view, "reveal", %{"key" => "NO_SUCH_KEY"})

      not_found_message = view |> element("#flash-error") |> render()
      assert not_found_message =~ "no longer exists"

      use_failing_secrets_store()
      row_id = row_id(view, "DATABASE_URL")
      unavailable_message = view |> element("#reveal-#{row_id}") |> render_click()

      refute unavailable_message =~ "no longer exists"
    end

    @tag action: "SEC-A05"
    test "the failure is distinguishable from success: the error element is present", %{
      conn: conn
    } do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      use_failing_secrets_store()

      view |> element("#reveal-#{row_id}") |> render_click()

      assert has_element?(view, "#flash-error")
    end

    @tag action: "SEC-A05"
    test "a forged phx-value-key containing '..' produces an error and no crash", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      render_click(view, "reveal", %{"key" => "../../other-env/secret"})

      assert has_element?(view, "#flash-error")
      assert has_element?(view, "#secrets-table")
      refute_audit_contains("../../other-env/secret")
    end
  end

  describe "SEC-S4 — reveal state is cleared on navigation" do
    test "navigating away and back closes the modal and drops the plaintext", %{conn: conn} do
      assert {:ok, %{value: db_value}} = Secrets.Store.get_secret("prod", "DATABASE_URL")
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      html = view |> element("#reveal-#{row_id}") |> render_click()
      assert html =~ db_value

      html = render_patch(view, "/environments/staging/secrets")
      refute html =~ db_value
      refute has_element?(view, "#secret-modal")

      html = render_patch(view, "/environments/prod/secrets")
      refute html =~ db_value
      refute has_element?(view, "#secret-modal")
      assert html =~ "View"
    end
  end

  describe "SEC-A16 — reject a well-formed but unknown environment" do
    @tag action: "SEC-A16"
    test "renders environment-not-found", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "nope")

      assert has_element?(view, "#secrets-environment-not-found")
      refute has_element?(view, "#secrets-table")
    end
  end

  describe "SEC-A15 — reject an invalid environment name" do
    @tag action: "SEC-A15"
    test "renders invalid-environment for path-traversal characters", %{conn: conn} do
      assert {:ok, view, _html} = live(conn, "/environments/..%2f..%2fetc/secrets")

      assert has_element?(view, "#secrets-invalid-environment")
      refute has_element?(view, "#secrets-table")
    end
  end

  describe "SEC-A17 — fail closed when environment validation is unavailable" do
    @tag action: "SEC-A17"
    test "renders validation-unavailable, distinct from not-found", %{conn: conn} do
      force_error(:tenant_api, :unavailable)

      assert {:ok, view, _html} = live_secrets(conn, "prod")

      assert has_element?(view, "#secrets-validation-unavailable")
      refute has_element?(view, "#secrets-environment-not-found")
      refute has_element?(view, "#secrets-table")
    end
  end

  describe "all three states keep the shell intact" do
    test "invalid name still renders the shell and no secrets controls", %{conn: conn} do
      assert {:ok, view, _html} = live(conn, "/environments/..%2f..%2fetc/secrets")

      assert has_element?(view, "#tenant-identifier")
      refute has_element?(view, "#secrets-table")
      refute has_element?(view, "#secrets-create-button")
    end

    test "not-found still renders the shell and no secrets controls", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "nope")

      assert has_element?(view, "#tenant-identifier")
      refute has_element?(view, "#secrets-table")
      refute has_element?(view, "#secrets-create-button")
    end

    test "unavailable still renders the shell and no secrets controls", %{conn: conn} do
      force_error(:tenant_api, :unavailable)

      assert {:ok, view, _html} = live_secrets(conn, "prod")

      assert has_element?(view, "#tenant-identifier")
      refute has_element?(view, "#secrets-table")
      refute has_element?(view, "#secrets-create-button")
    end
  end

  describe "patching between environments re-validates" do
    test "patching from a valid environment to an invalid one re-renders as invalid", %{
      conn: conn
    } do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      refute has_element?(view, "#secrets-invalid-environment")

      html = render_patch(view, "/environments/..%2f..%2fetc/secrets")

      assert html =~ ~s(id="secrets-invalid-environment")
      assert has_element?(view, "#secrets-invalid-environment")
    end

    test "patching from a valid environment to an unknown one re-renders as not-found", %{
      conn: conn
    } do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      render_patch(view, "/environments/nope/secrets")

      assert has_element?(view, "#secrets-environment-not-found")
    end
  end

  defp key_position(html, key) do
    :binary.match(html, key) |> elem(0)
  end

  # `SEC-S2` decision 2: the row id is a hash of the ARN, not the key — a
  # test selects on `[data-key="..."]` and reads the id LiveView actually
  # assigned, rather than recomputing the sha256 hash itself (`docs/adr/0010`).
  defp row_id(view, key) do
    document = view |> render() |> LazyHTML.from_fragment()

    ["secret-" <> hash] =
      document
      |> LazyHTML.query(~s([data-key="#{key}"]))
      |> LazyHTML.attribute("id")

    hash
  end
end
