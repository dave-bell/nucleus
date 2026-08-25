<!-- Context: project-intelligence/bridge | Priority: high | Version: 1.16 | Updated: 2026-08-24 -->

# Business ↔ Tech Bridge

> Document how business needs translate to technical solutions. This is the critical connection point.

## Quick Reference

- **Purpose**: Map binding requirement IDs onto this codebase's modules and tests
- **Purpose**: Define the tagging convention that makes requirement coverage checkable
- **Update When**: A feature area is implemented, or the wiki submodule is updated

## How Requirements Reach This Codebase

Requirements are **not** restated here. They live in the wiki submodule at
`docs/requirements/`, pinned to a specific commit so they cannot shift mid-task. This file
holds only the map and the convention.

```
docs/requirements/Secrets.md   →  SEC-A01 … SEC-A18   (the requirement)
        ↓
business-tech-bridge.md        →  SEC-* → NucleusWeb.SecretsLive   (the map, this file)
        ↓
test/.../secrets_live_test.exs →  @tag action: "SEC-A03"           (the proof)
```

Refresh requirements deliberately with:

```sh
git submodule update --remote docs/requirements
```

Then re-check the table below for new or renamed action IDs.

## Core Mapping

**114 actions across 10 pages.** Action IDs are stable and never renumbered, so they are safe
to cite from test names and bug reports.

| Requirement page | Action IDs | Count | Planned Phoenix surface | Planned test file |
|------------------|-----------|-------|-------------------------|-------------------|
| `Authentication-and-Access.md` | `AUTH-A01`–`A11` | 11 | Cognito Hosted UI redirect + session plug; `NucleusWeb.AuthController`, `on_mount` hook | `test/nucleus_web/auth_test.exs` |
| `Application-Shell-and-Navigation.md` | `NAV-A01`–`A12` | 12 | `NucleusWeb.Layouts` (app shell, header, sidebar) | `test/nucleus_web/live/shell_test.exs` |
| `Applications.md` | `APP-A01`–`A08` | 8 | `NucleusWeb.ApplicationsLive` (read-only Nomad jobs) | `test/nucleus_web/live/applications_live_test.exs` |
| `Environments.md` | `ENV-A01`–`A07` | 7 | `NucleusWeb.EnvironmentsLive` | `test/nucleus_web/live/environments_live_test.exs` |
| `Data-Export-Configuration.md` | `DEX-A01`–`A14` | 14 | `NucleusWeb.DataExportLive` + Nomad Variables client | `test/nucleus_web/live/data_export_live_test.exs` |
| `Secrets.md` | `SEC-A01`–`A18` | 18 | `NucleusWeb.SecretsLive` + SSM Parameter Store client | `test/nucleus_web/live/secrets_live_test.exs` |
| `M2M-Clients.md` | `M2M-A01`–`A18`, minus `A09` | 17 | `NucleusWeb.M2MClientsLive.Index` + `.Show` + Cognito client | `test/nucleus_web/live/m2m_clients_live_test.exs` |
| `Audit-and-Compliance.md` | `AUD-A01`–`A07` | 7 | `Nucleus.Audit` (emit-only; no local store — stateless constraint) | `test/nucleus/audit_test.exs` |
| `API-Proxy.md` | `PRX-A01`–`A07` | 7 | Backing-API forwarding layer | `test/nucleus_web/proxy_test.exs` |
| `Platform-Operations.md` | `OPS-A01`–`A13` | 13 | Health/readiness endpoints, config reference | `test/nucleus_web/ops_test.exs` |

`ENV-A05`'s wording changed (ENV-D1) — the error matrix no longer collapses "environment list
cannot be loaded" into the same "not found" case; it is now a distinct "temporarily unavailable"
state, matching `SEC-A17` and `Nucleus.Environments.fetch/2`'s `:unavailable` kind. No action ID
was added or removed, so the `ENV-A01`–`A07` / `7` count above is unchanged — a reader diffing
against an older commit should read this as a wording fix, not a coverage change.

**Most "Planned" columns are still unimplemented.** `NucleusWeb.Layouts` (app shell, header,
sidebar) and `test/nucleus_web/live/shell_test.exs` now exist (EN-7) — a deliberate subset only,
with no `@tag action:` claimed, so `NAV-A01`–`A12` coverage is still zero until the dedicated
`NAV-*` ticket lands. `NucleusWeb.SecretsLive` and `test/nucleus_web/live/secrets_live_test.exs`
also now exist (SEC-S1/#9, SEC-S2/#10, SEC-S3/#11, SEC-S4/#12, SEC-S5/#13, SEC-S6/#14) —
`SEC-A01`–`A14`, `A17` are claimed and covered; the module validates and resolves the environment,
lists a `Nucleus.Secrets` boundary's secrets **with no value column at all** (no plaintext and no
mask — ADR-0012), copies a row's path/ARN to the clipboard from icon-only buttons whose label is a
tooltip (`SEC-A02` — wiring only; the clipboard write itself is a recorded browser gap,
`docs/adr/0008-test-strategy.md`), reveals a value into a modal that is only in the DOM while it
is open, with a fresh audited fetch on every reveal, lets that same modal swap into an edit form
gated on the revealed secret matching by key (`SEC-A06`–`A08`, `docs/adr/0013-secret-edit-in-modal-and-value-form.md`),
creates a new secret through a second, independently conditionally-rendered modal
(`Nucleus.Secrets.Key`/`Nucleus.Secrets.create/4`, `SEC-A09`–`A13`) that closes whichever of the
two modals is open before opening the other, and renders every fail-closed/empty/failed-reveal/
failed-save/failed-create state. `SEC-A18` is `SEC-S7` and later. `M2M-A13`/`A14` are also now
claimed and covered (M2M-S1/#34), and `M2M-A01`/`A02` join them (M2M-S2/#35):
`NucleusWeb.M2MClientsLive.Index` (per Decision 7, two modules — `docs/adr/0018-m2m-clients-listing-module-split-and-dom-ids.md`
— not one module switching on `handle_params/3`) lists every visible client via
`Nucleus.M2M.list/1`, streamed with `phx-update="stream"` and a separate `:client_count` assign,
renders a `created_date_error` row as an explicit "unavailable" date rather than dropping it, and
shows a create affordance outside the empty-state conditional so it stays visible in both states.
`M2M-A03`/`A15`/`A16` join the claimed set too (M2M-S3/#36):
`NucleusWeb.M2MClientsLive.Show` replaces its M2M-S2 stub — `mount/3` (not `handle_params/3`,
since every navigation to a different `client_id` is a fresh remount, never a patch) resolves via
`Nucleus.M2M.fetch/2` on the disconnected render and `Nucleus.M2M.view/2` (`fetch/2` plus the
`m2m_client_viewed` audit emission) only once `connected?(socket)`, so the audit fires exactly
once per open with no disconnected-render flicker (`docs/adr/0019-m2m-client-detail-mount-audit-guard-and-token-validity.md`).
Renders client ID, name, scope, `Nucleus.M2M.TokenValidity.humanize/1`'s display of
`token_validity_seconds` (hours, else minutes, else seconds, singular at exactly one), and
creation date, plus an explicit secret-unavailable note; renders no rename/edit/delete control at
all (`M2M-A15`), and collapses every `Nucleus.Backend.Error` kind either to `States`' three shared
states or its own `#m2m-client-invalid-id`/`#m2m-client-not-found`, identically for a deny-listed
and a genuinely nonexistent ID.
`Nucleus.M2M.fetch/2` (`test/nucleus/m2m_test.exs`) is the context-layer gate every per-client M2M
action mounts through, the same relationship `Nucleus.Environments.fetch/2` has to
`NucleusWeb.SecretsLive`; `Nucleus.M2M.list/1` reuses its `visible?/1` predicate rather than a
second copy, pinned by a test that a client hidden from the list also 404s via `fetch/2`. `M2M-S1`
also delivers the pure naming/shape validators (`Nucleus.M2M.TicketId`/`Purpose`/`ClientId`/`ClientName`)
and the `Nucleus.M2M.DenyList` boundary `list/1` reads. `M2M-A04`–`A07` are now also claimed and
covered (M2M-S4/#37): `Nucleus.M2M.NewClient` (`test/nucleus/m2m/new_client_test.exs`) is a
no-repo `embedded_schema` changeset wrapping `TicketId.validate/1`/`Purpose.validate/1` with a
distinct message per reason atom, and `Index`'s `#new-m2m-client-modal` drives it with
`phx-change` validation and a `#new-m2m-client-name-preview` computed from
`Nucleus.M2M.ClientName.build/2` itself — never a template-side reconstruction — so the preview
is pinned equal to the string M2M-S5's create call will use. `M2M-A09` (duplicate-name
rejection) is not part of this count; it was dropped, not deferred, by EN-10/#33 (`docs/adr/0016-m2m-client-adapter.md`).
This ticket makes no backend write, so `save_new_client` still just flashed, same as M2M-S2's
placeholder — see M2M-S5 below for the real implementation. These names are the agreed target so
that work lands consistently — treat them as the convention to follow, and correct this table if
a better structure emerges.

`M2M-A08` and `M2M-A18` are now claimed and covered (M2M-S5/#38, `docs/adr/0020-m2m-client-creation-and-credentials-panel.md`):
`Nucleus.M2M.create/4` (note the arity — `token_validity_minutes` was added to the ticket's own
stale `create/3` plan text mid-implementation, per a later issue comment) validates
`ticket_id`/`purpose`, builds the name server-side via `ClientName.build/2` (never taken from the
caller), checks `DenyList.suffixes/0` then `denied?/1` against it — in that order, not `denied?/1`
alone, so an unconfigured deny-list surfaces its own `:not_configured` rather than a false
`:reserved_name` on every input — and calls `Clients.create_client/2` only once both pass, auditing
`m2m_client_created` on success only. `NucleusWeb.M2MClientsLive.CredentialsPanel` is the shared
one-time secret panel (reused verbatim by `M2M-S6`/#39's rotation): deliberately not built on
`<.modal>`, since `M2M-A08` requires the secret be copyable *before leaving the screen* and a
backdrop click or stray Escape must not be able to discard the only copy — the panel carries no
`phx-click-away`/`phx-window-keydown` at all, only its own explicit dismiss control.
`Index`'s `save_new_client` now: closes the creation modal and opens this panel on success,
re-lists (`Nucleus.M2M.list/1`) rather than computing a `stream_insert/3` position — the same
choice ADR-0014 made for Secrets creation, for the same anti-drift reason — and clears
`:credentials` when the creation modal reopens, the same `focusStack`-double-pop guard ADR-0014
applied to Secrets' own two conditionally-rendered modals. `M2M-A05`/`A06`'s server-side claim
(direct `save_new_client` dispatch bypassing the disabled submit button) is proven again here,
tagged as such per the ticket's own instruction that the tags stay with M2M-S4/#37.

`NucleusWeb.EnvironmentsLive` and `test/nucleus_web/live/environments_live_test.exs` also now
exist (ENV-S1/#52): `ENV-A02`–`A07` are claimed and covered. `ENV-A01` (sidebar category
grouping/expand) remains unclaimed — `NAV-S1`'s job. The module mirrors `NucleusWeb.SecretsLive`'s
`handle_params/3`/kind→DOM-id pattern one boundary narrower (`Nucleus.Environments.fetch/2` only,
no `Nucleus.Secrets` boundary to also match on), renders the IRI as escaped text with a
`<.copy_button>` alongside an `#open-iri` "open in new tab" link — `iri_href/1` only allows the
link when the IRI's scheme is `http`/`https` with a host, so an unsafe scheme (e.g.
`javascript:`) never reaches an `href`, only the raw text — and validates `accent_color` against
a hex allowlist before it ever reaches a `style=` attribute — a non-conforming value falls back
to a neutral swatch, with the raw string still shown as text. The sidebar's `#environments-list`
link
(`lib/nucleus_web/components/layouts.ex`) now points at this route instead of straight to
`.../secrets`; `Manage Secrets` on the detail page is what reaches `NucleusWeb.SecretsLive` now.

Two conformance notes worth carrying forward, both recorded in
`docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md`:
`SEC-A03`'s "the control changes to 'Hide'" is **not** implemented literally — the row's control
always reads "View" and the modal's dismiss controls are the hide affordance. `SEC-A04`/`SEC-A13`
are each claimed on their modal's plain-`phx-click` dismiss control only (Close, Cancel) — the
one dismissal route `Phoenix.LiveViewTest` can drive; Escape and a backdrop click are wiring-only
browser gaps for both modals.

## Tagging Convention

Tag every test with the action ID it proves. ExUnit supports this natively, so no tooling is
needed to use it:

```elixir
describe "SEC-A03 — reveal a secret's value" do
  @tag action: "SEC-A03"
  test "opens a modal holding the plaintext and its own copy affordance", %{conn: conn} do
    # ...
  end
end
```

Run a single requirement's tests:

```sh
mix test --only action:SEC-A03
```

List every action ID defined in the requirements (yields 114):

```sh
rg -o --no-filename '^### ([A-Z0-9]+-A[0-9]+)' -r '$1' docs/requirements/ -g '!Home.md' | sort -u
```

Both flags matter. `--no-filename` is required or `rg` prefixes each match with its path and
`sort -u` silently stops deduping. `-g '!Home.md'` excludes the `SEC-A03` block at
`Home.md:77`, which is the wiki's worked example of action formatting, not a 114th requirement.

List every action ID currently claimed by a test:

```sh
rg -o --no-filename 'action: "([A-Z0-9]+-A[0-9]+)"' -r '$1' test/ | sort -u
```

Diffing those two lists by hand gives requirement coverage. `mix nucleus.trace` (EN-8,
`docs/adr/0008-test-strategy.md`) automates exactly this diff — run it instead of the two `rg`
commands above for day-to-day use:

```sh
mix nucleus.trace                # full report: covered / uncovered / claimed-but-undefined
mix nucleus.trace --feature SEC  # one action prefix only
mix nucleus.trace --exitcode     # non-zero exit when anything in scope is uncovered
```

Report-only today — not wired into `mix precommit` while most `SEC-*` tickets remain
unimplemented; see `living-notes.md`.

## Reading a Requirement Against This Stack

Each wiki action has an `Actor` / `Given` / `When` / `Then`, and often an `API:` line and an
`Audit:` line.

| Part of the action | Status here |
|--------------------|-------------|
| `Actor`, `Given`, `When`, `Then` | **Binding.** Transport-agnostic — describes observable behaviour. |
| `Audit:` event name and fields | **Binding.** Event names and "value never logged" rules hold. |
| Validation limits (e.g. key ≤256 chars, value ≤4096, no `/`, `\`, `..`) | **Binding.** |
| Status codes (400/401/404/409/503) | **Binding as behaviour**, not as literal HTTP responses in a LiveView. A 409 means "reject and tell the user it already exists". |
| `API: GET /api/secrets/{environment}/{key}` | **Advisory.** Names the operation, not the transport. In LiveView this is a `handle_event` plus a context function, not a REST route. Do not build a REST layer purely to satisfy this line. |
| `Test layer:` (unit / integration / e2e) | **Advisory guidance.** Map to ExUnit unit tests, `Phoenix.LiveViewTest`, and mocked backend contract tests. |

## Feature Mapping Example: Secrets

**Business Context**:
- User need: read and change per-environment secrets without AWS console access
- Business goal: remove standing AWS credentials from Ops/Support workstations
- Priority: highest-risk surface — it handles plaintext secret material

**Technical Implementation**:
- Solution: `NucleusWeb.SecretsLive` over an SSM Parameter Store client behind a swappable
  behaviour, reached by assuming a scoped role in the tenant's AWS account
- Architecture: values fetched live per reveal; nothing cached (stateless constraint), and a
  revealed value exists in the DOM only while its modal is drawn
- Trade-offs: `SEC-A06` requires a value be *revealed before it can be edited*, deliberately
  trading a slower edit path for protection against blind overwrites. The edit control lives
  inside the reveal modal itself, not a row — reveal state exists only while that modal is open,
  so a row-level control would dead-end against the gate almost every time
  (`docs/adr/0013-secret-edit-in-modal-and-value-form.md`).

**Connection**:
Secrets is where the read+update-only boundary earns its keep. There is no delete, so a
mis-click cannot destroy a value another system depends on. Audit events
(`secret_created`, `secret_viewed`, `secret_updated`) record the parameter path but **never
the value**, so the audit trail is safe to retain and review.

## Trade-off Decisions

| Situation | Business Priority | Technical Priority | Decision Made | Rationale |
|-----------|-------------------|-------------------|---------------|-----------|
| Wiki specifies REST endpoints; LiveView has no such layer | Behaviour must match the spec | Avoid a REST layer built only to satisfy a doc | Honour Given/When/Then; treat `API:` lines as operation names | Users experience behaviour, not routes |
| Wiki says stateless; generator added Postgres | Auditability without a local store | Ecto is already wired in | Unresolved — tracked in `living-notes.md` | Needs a real decision, not a silent default |

## Common Misalignments

| Misalignment | Warning Signs | Resolution Approach |
|--------------|---------------|---------------------|
| Requirement text copied into context files | Context files grow past 200 lines; wording drifts from the wiki | Delete the copy; cite the action ID instead |
| Tests written without action tags | `mix test --only action:...` returns nothing for a shipped feature | Add `@tag action:` when writing the test, not later |
| Wiki architecture treated as this project's design | A REST/plugin layer appears with no requirement behind it | Re-read the scope note in `business-domain.md` |
| Submodule left stale for months | Requirements discussed verbally that no action ID covers | `git submodule update --remote docs/requirements` |

## Onboarding Checklist

- [ ] Initialise the `docs/requirements/` submodule
- [ ] Know which of the 10 action prefixes maps to which planned module
- [ ] Be able to run `mix test --only action:SEC-A03`
- [ ] Know which parts of a wiki action are binding and which are advisory
- [ ] Add `@tag action:` to every new test

## Related Files

- `business-domain.md` - Business needs and the binding-requirements scope note
- `technical-domain.md` - Stack and constraints
- `decisions-log.md` - Decisions made with full context
- `living-notes.md` - Open questions, including `mix nucleus.trace`
