<!-- Context: project-intelligence/technical | Priority: high | Version: 1.1 | Updated: 2026-08-07 -->

# Technical Domain

> Document the technical foundation, architecture, and key decisions.

## Quick Reference

- **Purpose**: Understand how the project works technically
- **Update When**: New features, refactoring, tech stack changes
- **Audience**: Developers, DevOps, technical stakeholders

## Code Standards: See `AGENTS.md`

`AGENTS.md` at the project root is the **authoritative** source for Elixir, Phoenix, HEEx,
LiveView, Ecto, and Tailwind conventions, including naming, forms, streams, and JS interop.
It is not duplicated here — read it directly. This file covers only stack, structure, and
constraints specific to Nucleus.

## Primary Stack

| Layer | Technology | Version | Rationale |
|-------|-----------|---------|-----------|
| Language | Elixir | `1.20.3-otp-29` (`.tool-versions`); `~> 1.17` floor in `mix.exs` | [Rationale not yet recorded] |
| Framework | Phoenix | `~> 1.8.9` | [Rationale not yet recorded] |
| UI | Phoenix LiveView | `~> 1.2.0` | Server-rendered interactive UI without a separate frontend app |
| Web server | Bandit | `~> 1.5` | Phoenix 1.8 default |
| Database | **None — no local datastore.** `ecto` (`~> 3.13`) + `phoenix_ecto` (`~> 4.5`) are retained for `embedded_schema`/`Ecto.Changeset` form validation only | `~> 3.13` | Enforces the stateless constraint. `ecto_sql`/`postgrex` removed by EN-1 — see `docs/adr/0001-no-local-datastore.md`. **Do not add a repo.** |
| HTTP client | Req | `~> 0.5` | Required by `AGENTS.md`; never use `httpoison`/`tesla`/`httpc` |
| Styling | Tailwind CSS | `4.3.0` (`config/config.exs:51`) | v4, no `tailwind.config.js` |
| Icons/components | heroicons `v2.2.0`, daisyui `v5.5.20` | pinned git deps | Vendored via `mix.exs` |
| Asset bundling | esbuild | `0.25.4` (`config/config.exs:41`) | Only `app.js`/`app.css` bundles are supported |
| Mail | Swoosh | `~> 1.16` | Generator default; no mail requirement identified yet |
| Telemetry | `telemetry_metrics`, `telemetry_poller`, `phoenix_live_dashboard` | `~> 1.0`, `~> 0.8.3` | Generator default |

## Architecture Pattern

```
Type: Monolith (Phoenix application)
Pattern: LiveView-first server-rendered control plane over three external backing systems
Diagram: Not yet produced for this codebase
```

### Why This Architecture?

Not yet formally decided — no entry exists in `decisions-log.md`. The current shape is the
unmodified output of `mix phx.new` plus the constraints below.

**Do not treat the wiki's architecture diagram as this project's design.** That diagram
(a React frontend over a Python API with three plugins) describes an earlier prototype.
This project is a fresh start. Requirements bind; that architecture does not.

## Project Structure

```
2026-08-07-nucleus2/
├── lib/nucleus/            # Core application + OTP supervision
│   ├── application.ex      # Supervision tree (no repo — see adr/0001)
│   └── mailer.ex
├── lib/nucleus_web/        # Web layer
│   ├── router.ex           # Currently only `get "/"` + dev routes
│   ├── endpoint.ex
│   ├── components/         # core_components.ex, layouts
│   └── controllers/        # page_controller.ex, error views
├── test/                   # Mirrors lib/ structure
├── docs/requirements/      # Wiki submodule — BINDING requirements source
├── docs/adr/               # This project's own ADRs (0001: no local datastore)
├── assets/                 # app.js, app.css
└── config/                 # config.exs, dev/test/prod/runtime
```

**Key Directories**:
- `lib/nucleus/` — business logic and contexts, organised by domain as features land
- `lib/nucleus_web/` — LiveViews, components, router; no feature LiveViews exist yet
- `test/` — mirrors `lib/`; requirement action IDs are tagged here (see `business-tech-bridge.md`)
- `docs/requirements/` — pinned wiki checkout; **read, never edit from this repo**
- `docs/adr/` — where this project's own architecture decisions go

## Key Technical Decisions

| Decision | Rationale | Impact |
|----------|-----------|--------|
| *(none recorded)* | — | — |

No architectural decisions have been made and recorded yet. See `decisions-log.md`.

## Integration Points

All three are external, tenant-owned, and read live — there is no local mirror.

| System | Purpose | Protocol | Direction |
|--------|---------|----------|-----------|
| Nomad Variables | Tenant-wide config, primarily Data Export settings | HTTP API | Outbound (read + update) |
| Nomad jobs | Read-only visibility into deployed applications | HTTP API | Outbound (read) |
| AWS SSM Parameter Store | Per-environment encrypted secrets, in the tenant's own AWS account via an assumed scoped role | AWS API | Outbound (read, create, update — no delete) |
| Cognito User Pool | Authentication (Hosted UI, federated to corporate IdP) and M2M app clients | OAuth 2.0 / AWS API | Inbound (auth) + Outbound (client create/rotate) |
| Tenant backing API | Authoritative list of the tenant's environments | HTTP API | Outbound (read) |

## Technical Constraints

| Constraint | Origin | Impact |
|------------|--------|--------|
| **Stateless — no own datastore** | Adopted from wiki Core model | Every value is fetched live per request. No cache of secrets or config survives a restart. **Structurally enforced since EN-1**: there is no repo, no `ecto_sql`, no database config. Adding one reopens `docs/adr/0001-no-local-datastore.md`. Audit records go to an external log pipeline (EN-5), never a local table. |
| **Pluggable backends** | Adopted from wiki Core model | Nomad, Parameter Store, and Cognito must sit behind swappable interfaces (idiomatically, Elixir behaviours) so a backing system can be replaced without changing behaviour. Enables local/test implementations. |
| **Token passthrough** | Adopted from wiki Core model | Nucleus holds no authorisation model of its own for backing APIs; it forwards the signed-in user's access token. **Non-trivial in LiveView** — the token must be held against a long-lived stateful socket and mid-session expiry handled. See `living-notes.md` and requirement `SEC-A18`. |
| **Fail closed on validation** | Requirements (`SEC-A15`–`SEC-A17`) | Environment names are validated against the tenant's backing API before any path is constructed. If validation is unavailable, requests are rejected, never passed through unvalidated. |
| **Single tenant per deployment** | Business constraint | Namespace is deployment configuration, not runtime state. |
| **Desktop only** | Business constraint | No responsive/mobile layout work required. |

## Development Environment

```
Setup: mix setup      # deps.get, assets.setup, assets.build
Requirements: Elixir 1.20.3 / OTP 29 (see .tool-versions, via asdf or mise)
              No database required — Nucleus has no local datastore.
              Clone submodules: git submodule update --init --recursive
Local Dev: mix phx.server   (or: iex -S mix phx.server) → http://localhost:4000
Testing: mix test           # no database setup; no external services needed
Pre-flight: mix precommit   # compile --warnings-as-errors, deps.unlock --unused, format, test
```

`mix precommit` is the required gate before finishing any change (see `AGENTS.md`).

## Deployment

```
Environment: [Not yet defined]
Platform: [Not yet defined — Nomad is a managed system, not a confirmed deploy target]
CI/CD: [Not yet defined — no workflows in this repo]
Monitoring: LiveDashboard at /dev/dashboard (dev only, unauthenticated — must be gated
            before any production exposure)
```

## Onboarding Checklist

- [ ] Read `AGENTS.md` in full — it governs all code style
- [ ] Know the primary tech stack and that there is **no database** (`adr/0001`)
- [ ] Understand the five constraints and which are architectural
- [ ] Know the three backing systems and that all reads are live
- [ ] Initialise the `docs/requirements/` submodule
- [ ] Be able to run `mix setup`, `mix phx.server`, and `mix precommit`
- [ ] Understand that the wiki's architecture does not bind this codebase

## Related Files

- `AGENTS.md` (project root) - **authoritative** code standards
- `business-domain.md` - Why this technical foundation exists
- `business-tech-bridge.md` - Requirement ID → module → test mapping
- `decisions-log.md` - Decision history
- `living-notes.md` - Token passthrough risk, open questions
