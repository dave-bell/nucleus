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
    test "the mask is a fixed width regardless of the underlying value's length", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      db_row = view |> element("[data-key=\"DATABASE_URL\"]") |> render()
      jwt_row = view |> element("[data-key=\"JWT_SIGNING_KEY\"]") |> render()

      mask_regex = ~r/<span aria-hidden="true">(.*?)<\/span>/s
      assert [_, db_mask] = Regex.run(mask_regex, db_row)
      assert [_, jwt_mask] = Regex.run(mask_regex, jwt_row)

      assert db_mask == jwt_mask
      assert String.length(jwt_mask) < 20
    end

    @tag action: "SEC-A01"
    test "the reveal control is present per row", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")

      assert has_element?(view, "button[phx-value-key=\"DATABASE_URL\"]")
      assert has_element?(view, "button[phx-value-key=\"STRIPE_API_KEY\"]")
      assert has_element?(view, "button[phx-value-key=\"JWT_SIGNING_KEY\"]")
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

        assert LazyHTML.query(doc, "[id^=\"copy-path-\"]") != []
        assert LazyHTML.query(doc, "[id^=\"copy-arn-\"]") != []
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

      assert LazyHTML.query(doc, "[aria-live=\"polite\"]") != []
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
    test "shows plaintext, a copy affordance, and flips the control to Hide", %{conn: conn} do
      assert {:ok, %{value: db_value}} = Secrets.Store.get_secret("prod", "DATABASE_URL")
      assert {:ok, view, html} = live_secrets(conn, "prod")
      refute html =~ db_value

      row_id = row_id(view, "DATABASE_URL")

      html = view |> element("#reveal-#{row_id}") |> render_click()

      assert html =~ db_value
      assert has_element?(view, "#secret-value-#{row_id}")
      assert has_element?(view, "#copy-value-#{row_id}")
    end

    @tag action: "SEC-A03"
    test "the control's label is now Hide", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      view |> element("#reveal-#{row_id}") |> render_click()

      assert view |> element("#reveal-#{row_id}") |> render() =~ "Hide"
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
  end

  describe "SEC-A04 — hide a revealed secret's value" do
    @tag action: "SEC-A04"
    test "clicking Hide removes the plaintext from the payload and restores View", %{
      conn: conn
    } do
      assert {:ok, %{value: db_value}} = Secrets.Store.get_secret("prod", "DATABASE_URL")
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      view |> element("#reveal-#{row_id}") |> render_click()
      html = view |> element("#reveal-#{row_id}") |> render_click()

      refute html =~ db_value
      refute has_element?(view, "#secret-value-#{row_id}")
      assert html =~ "View"
    end

    @tag action: "SEC-A04"
    test "hiding emits no audit event", %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      view |> element("#reveal-#{row_id}") |> render_click()
      assert_audit_event(:secret_viewed)

      view |> element("#reveal-#{row_id}") |> render_click()

      assert length(audit_events()) == 1
    end

    @tag action: "SEC-A04"
    test "reveal -> hide -> reveal works and emits two events", %{conn: conn} do
      assert {:ok, %{value: db_value}} = Secrets.Store.get_secret("prod", "DATABASE_URL")
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      html = view |> element("#reveal-#{row_id}") |> render_click()
      assert html =~ db_value

      html = view |> element("#reveal-#{row_id}") |> render_click()
      refute html =~ db_value

      html = view |> element("#reveal-#{row_id}") |> render_click()
      assert html =~ db_value

      events = Enum.filter(audit_events(), &(&1.event == :secret_viewed))
      assert length(events) == 2
    end
  end

  describe "SEC-A05 — handle a failed reveal" do
    @tag action: "SEC-A05"
    test "store forced :unavailable: error flash shown, value stays absent, control stays View, view alive",
         %{conn: conn} do
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      use_failing_secrets_store()

      html = view |> element("#reveal-#{row_id}") |> render_click()

      assert has_element?(view, "#flash-error")
      refute has_element?(view, "#secret-value-#{row_id}")
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
    test "navigating away and back clears the reveal", %{conn: conn} do
      assert {:ok, %{value: db_value}} = Secrets.Store.get_secret("prod", "DATABASE_URL")
      assert {:ok, view, _html} = live_secrets(conn, "prod")
      row_id = row_id(view, "DATABASE_URL")

      html = view |> element("#reveal-#{row_id}") |> render_click()
      assert html =~ db_value

      html = render_patch(view, "/environments/staging/secrets")
      refute html =~ db_value

      html = render_patch(view, "/environments/prod/secrets")
      refute html =~ db_value
      assert html =~ "View"
    end
  end

  describe "SEC-S4 — multiple independent reveals" do
    test "revealing two secrets independently, then hiding one, leaves the other revealed", %{
      conn: conn
    } do
      assert {:ok, %{value: db_value}} = Secrets.Store.get_secret("prod", "DATABASE_URL")
      assert {:ok, %{value: stripe_value}} = Secrets.Store.get_secret("prod", "STRIPE_API_KEY")

      assert {:ok, view, _html} = live_secrets(conn, "prod")
      db_row_id = row_id(view, "DATABASE_URL")
      stripe_row_id = row_id(view, "STRIPE_API_KEY")

      view |> element("#reveal-#{db_row_id}") |> render_click()
      html = view |> element("#reveal-#{stripe_row_id}") |> render_click()

      assert html =~ db_value
      assert html =~ stripe_value

      html = view |> element("#reveal-#{db_row_id}") |> render_click()

      refute html =~ db_value
      assert html =~ stripe_value
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
