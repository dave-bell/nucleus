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
| The `beforeunload` warning dialog itself | `M2M-A10` | `window.beforeunload` is a browser API; the hook cannot be executed |

For these, assert the *wiring* (hook attached, `phx-window-keydown` bound,
`on_cancel` set) — never tag the test `action:` for that ID, since the test
does not prove the requirement's `Then` clauses. `SEC-A04` is the one partial
case: its `Then` *is* proven, through the modal's Close button, which pushes a
plain event a `render_click/1` can drive. The tag is claimed there and only
there — see `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md`.

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
