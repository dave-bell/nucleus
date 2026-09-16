# Test suite

## Test layers

| Layer | What it verifies | How |
|---|---|---|
| Unit | Pure functions — validation, path construction, encoding | No process, no backend, no LiveView |
| Contract | A local implementation and its real counterpart satisfy the same behaviour | `test/support/*_contract.ex`, run against both via `use ...Contract` |
| Integration (mocked) | LiveViews, routes, plug pipeline, wiring | `Phoenix.LiveViewTest` and `PhoenixTest` against the local backends |
| Integration (external) | The real implementation against the real backing service | `:external` tag — excluded by default, see below |

There is no browser-driven e2e layer. `Phoenix.LiveViewTest` (mount,
`handle_event`, `handle_params`, patches, redirects, flash) plus `PhoenixTest`
(cross-page flows, static and live) cover what Playwright covered for the
prototype's React SPA — decided on issue #8; recorded as `docs/adr/0008-test-strategy.md`
in a follow-up commit once this lands, per `ticket-delivery.md`'s "After
Merge" convention (not yet present at review time — do not follow this link
until that commit exists). Two things genuinely cannot be tested this way
and are tracked as residual gaps in `living-notes.md`, never claimed as
covered:

| Gap | Action | Why |
|---|---|---|
| Clipboard write and its visual confirmation | `SEC-A02` | `navigator.clipboard` is a browser API |
| Tooltip reveal on hover / `:focus-visible` | `SEC-A02` | daisyUI `.tooltip` is CSS pseudo-element state |
| Escape-key dismissal, focus trap, focus restoration | `SEC-A13` | Real key events and focus management need a browser |
| Escape and backdrop-click dismissal of the reveal modal | `SEC-A04` | Both reach the server only by running the `JS` chain in `data-cancel` |
| Escape and backdrop-click dismissal of the environment picker | `DEX-A11` | Same `data-cancel` chain as `SEC-A04`; claimed here through the picker's own Cancel button instead |
| The `beforeunload` warning dialog itself | `M2M-A10` | `window.beforeunload` is a browser API; the hook cannot be executed |
| The rendered status colour itself (as opposed to the CSS class) | `APP-A02` | Actual pixel colour is not observable through `Phoenix.LiveViewTest`; only the class attribute is |
| Click-away dismissal of the user menu | `NAV-A08` | `phx-click-away` reaches the server via a real DOM click outside the element; no `LiveViewTest` helper drives a "click elsewhere" |

For these, assert the *wiring* (hook attached, `phx-window-keydown` bound,
`on_cancel` set) — never tag the test `action:` for that ID, since the test
does not prove the requirement's `Then` clauses. `SEC-A04`, `DEX-A11`,
`APP-A02`, and `NAV-A08` are partial cases: each `Then` *is* proven through a
mechanism `Phoenix.LiveViewTest` can drive — `SEC-A04` and `DEX-A11` through
their respective modal's Close/Cancel button (a plain event `render_click/1`
can push), `APP-A02` through the per-status CSS class
(`has_element?(view, "#job-...-status.badge-success")`, asserted pairwise
distinct across `running`/`pending`/`dead`), `NAV-A08` through
`render_click/2` (open/close, email, Logout) and `render_keydown/3` (Escape,
via the real `"close-user-menu"` event `phx-window-keydown` pushes) — so the
tag is claimed there and only the un-drivable remainder (backdrop/Escape
dismissal for the earlier three; the true click-away for `NAV-A08`; the
rendered pixel) stays an open gap. See
`docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md` and
`docs/adr/0026-applications-row-formatters-and-status-colour-test-gap.md`
respectively.

## Tag vocabulary

| Tag | Meaning | Effect |
|---|---|---|
| `:external` (`@describetag`/`@tag`) | Exercises a real backing service (real AWS, real Nomad, real Cognito), not a local implementation | Excluded by default (`test/test_helper.exs`); run with `mix test --include external` |
| `@tag :unit` | A fast, no-backend, no-LiveView test | Documentation only — no `ExUnit.start/1` effect, but keeps `mix test --only unit` meaningful |
| `@tag action: "SEC-A03"` | This test proves requirement `SEC-A03`'s `Given`/`When`/`Then` | Run just that requirement's tests: `mix test --only action:SEC-A03`. Tracked by `mix nucleus.trace` |

## The `action:` traceability convention

One `describe` block per action ID, titled with the ID and its summary; every
test inside tagged with that ID:

```elixir
describe "SEC-A03 — reveal a secret's value" do
  @tag action: "SEC-A03"
  test "reveals plaintext and flips the control to Hide", %{conn: conn} do
    # ...
  end
end
```

**Claim an ID only when the test genuinely proves the `Then` clauses.** A
wiring-only assertion (see the `SEC-A02`/`SEC-A13` gaps above) does not earn
the tag — claim coverage that does not exist, and `mix nucleus.trace` cannot
catch it, but the requirement is not actually proven.

Run `mix nucleus.trace` to diff every `### PREFIX-A##` defined under
`docs/requirements/` against every `@tag action:` claimed here — see
`mix help nucleus.trace` for `--feature` and `--exitcode`. Full convention and
the ID-to-module map: `business-tech-bridge.md`.

## Test support (`test/support/`)

| Module | For | Composes |
|---|---|---|
| `NucleusWeb.ConnCase` | Any test needing a `Plug.Conn` | — |
| `Nucleus.BackendCase` | Seeding/mutating the local `TenantApi`/`Secrets.Store` backends, or injecting a fault | Wraps `Nucleus.Backend.Seed` (global) and `Nucleus.Backend.Faults`' env vars — **`async: false`**, see its moduledoc |
| `Nucleus.AuditCase` | Asserting on emitted `Nucleus.Audit` records | Wraps `Nucleus.Audit.Sink.Test` — `async: true` safe |
| `NucleusWeb.LiveCase` | Mounting a real LiveView | `ConnCase` + `BackendCase` + `AuditCase` + `Phoenix.LiveViewTest` |

Auth is disabled by default in every test (`Nucleus.Scope.Provider.Disabled`,
`docs/adr/0005-deferred-authentication.md`) — there is no sign-in step to
perform before mounting a LiveView.
