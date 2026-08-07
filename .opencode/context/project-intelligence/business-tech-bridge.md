<!-- Context: project-intelligence/bridge | Priority: high | Version: 1.0 | Updated: 2026-08-07 -->

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

**113 actions across 10 pages.** Action IDs are stable and never renumbered, so they are safe
to cite from test names and bug reports.

| Requirement page | Action IDs | Count | Planned Phoenix surface | Planned test file |
|------------------|-----------|-------|-------------------------|-------------------|
| `Authentication-and-Access.md` | `AUTH-A01`–`A11` | 11 | Cognito Hosted UI redirect + session plug; `NucleusWeb.AuthController`, `on_mount` hook | `test/nucleus_web/auth_test.exs` |
| `Application-Shell-and-Navigation.md` | `NAV-A01`–`A12` | 12 | `NucleusWeb.Layouts` (app shell, header, sidebar) | `test/nucleus_web/live/shell_test.exs` |
| `Applications.md` | `APP-A01`–`A08` | 8 | `NucleusWeb.ApplicationsLive` (read-only Nomad jobs) | `test/nucleus_web/live/applications_live_test.exs` |
| `Environments.md` | `ENV-A01`–`A07` | 7 | `NucleusWeb.EnvironmentsLive` | `test/nucleus_web/live/environments_live_test.exs` |
| `Data-Export-Configuration.md` | `DEX-A01`–`A14` | 14 | `NucleusWeb.DataExportLive` + Nomad Variables client | `test/nucleus_web/live/data_export_live_test.exs` |
| `Secrets.md` | `SEC-A01`–`A18` | 18 | `NucleusWeb.SecretsLive` + SSM Parameter Store client | `test/nucleus_web/live/secrets_live_test.exs` |
| `M2M-Clients.md` | `M2M-A01`–`A16` | 16 | `NucleusWeb.M2MClientsLive` + Cognito client | `test/nucleus_web/live/m2m_clients_live_test.exs` |
| `Audit-and-Compliance.md` | `AUD-A01`–`A07` | 7 | `Nucleus.Audit` (emit-only; no local store — stateless constraint) | `test/nucleus/audit_test.exs` |
| `API-Proxy.md` | `PRX-A01`–`A07` | 7 | Backing-API forwarding layer | `test/nucleus_web/proxy_test.exs` |
| `Platform-Operations.md` | `OPS-A01`–`A13` | 13 | Health/readiness endpoints, config reference | `test/nucleus_web/ops_test.exs` |

**Nothing in the "Planned" columns exists yet.** The router currently serves only `get "/"`.
These names are the agreed target so that work lands consistently — treat them as the
convention to follow, and correct this table if a better structure emerges.

## Tagging Convention

Tag every test with the action ID it proves. ExUnit supports this natively, so no tooling is
needed to use it:

```elixir
describe "SEC-A03 — reveal a secret's value" do
  @tag action: "SEC-A03"
  test "reveals plaintext and flips the control to Hide", %{conn: conn} do
    # ...
  end
end
```

Run a single requirement's tests:

```sh
mix test --only action:SEC-A03
```

List every action ID defined in the requirements (yields 113):

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

Diffing those two lists gives requirement coverage. Automating it as `mix nucleus.trace` and
adding it to the `precommit` alias is an open item in `living-notes.md`.

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
- Architecture: values fetched live per reveal; nothing cached (stateless constraint)
- Trade-offs: `SEC-A06` requires a value be *revealed before it can be edited*, deliberately
  trading a slower edit path for protection against blind overwrites

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
