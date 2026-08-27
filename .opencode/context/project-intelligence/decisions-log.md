<!-- Context: project-intelligence/decisions | Priority: high | Version: 1.28 | Updated: 2026-08-26 -->

# Decisions Log

> The index of settled architectural decisions. Full context — rationale, alternatives,
> consequences, cross-references — lives in the linked ADR. This file is a pointer, never a
> duplicate: one row per decision, no prose sections.

## Quick Reference

- **Purpose**: Point future readers at the right ADR before they re-debate a settled question
- **Format**: One index row per decision. `docs/adr/` carries everything else, including each
  ADR's own `## References` (deciding issue, sibling ADRs, downstream tickets)
- **Status**: Decided | Pending | Under Review | Deprecated
- **Size**: 200-line MVI ceiling, held structurally — a row costs ~1 line, so the ceiling is not
  reachable by normal growth. **Do not reintroduce per-decision prose sections**: they made this
  file a third copy of the ADR and breached the ceiling at ten decisions (see v1.11)

## Adding a Decision

Append a row below. Write the ADR first — if the summary won't fit one row, the ADR is doing its
job and the row should point rather than paraphrase.

## Decision Index

| # | Decision | Date | Status | ADR |
|---|----------|------|--------|-----|
| 1 | No local datastore — drop `ecto_sql`/`postgrex`, keep `ecto` for changesets; stateless constraint now structurally enforced | 2026-08-07 | Decided | `docs/adr/0001-no-local-datastore.md` |
| 2 | Backend adapter boundaries — behaviours, tagged-tuple errors over six neutral `kind`s, per-boundary real/local selection, never raising; fault injection required | 2026-08-07 | Decided | `docs/adr/0002-backend-adapter-boundaries.md` |
| 3 | Shared local backend seed — one supervised `Agent`, boundary-neutral, started everywhere; superseded EN-3's own `GenServer`+ETS plan | 2026-08-11 | Decided | `docs/adr/0003-shared-local-backend-seed.md` |
| 4 | Audit emission — bypasses `Logger`, synchronous `Sink` in the caller's process, failures never rescued, per-event field allowlist with no key named `value` | 2026-08-11 | Decided | `docs/adr/0004-audit-emission.md` |
| 5 | Deferred authentication — `Nucleus.Scope` seam, disabled-by-default provider, fail-loud `AUTH_ENABLED`; `token` stays `nil` until substituted | 2026-08-11 | Decided | `docs/adr/0005-deferred-authentication.md` |
| 6 | Application shell & live session composition — daisyUI retained (reversing the ticket's own removal call), stacked `on_mount` hooks, sidebar degrades while Secrets stays fail-closed | 2026-08-11 | Decided | `docs/adr/0006-application-shell-and-live-session-composition.md` |
| 7 | Secrets store adapter — cluster/deployment Parameter Store path, `aws` package over `ex_aws`, `:persistent_term` credential cache, no dedicated local `Agent` | 2026-08-12 | Decided | `docs/adr/0007-secrets-store-adapter.md` |
| 8 | Test strategy — `Phoenix.LiveViewTest` + `PhoenixTest`, no browser driver (`SEC-A02`/`SEC-A13` left as recorded browser-only gaps); `BackendCase`/`AuditCase`/`LiveCase`; `mix nucleus.trace` report-only | 2026-08-14 | Decided | `docs/adr/0008-test-strategy.md` |
| 9 | Environment validation ladder — allowlist over denylist, strict validate-then-fetch ordering, no cache/no fallback ever, validation errors tagged `boundary: :tenant_api` | 2026-08-14 | Decided | `docs/adr/0009-environment-validation-ladder.md` |
| 10 | Secrets listing — one context call replaces two, ARN-hashed DOM ids with `data-key` carrying the real key, errors matched on `{kind, boundary}` | 2026-08-17 | Decided | `docs/adr/0010-secrets-listing-gate-collapse-and-dom-ids.md` |
| 11 | Secret reveal — re-stream a converted `SecretRef` (never the value-bearing `Secret`), audit `user:` via `Scope.audit_user/1`, `Nucleus.Audit.Sink.Test` falls back to `$callers` for LiveView-emitted audit events | 2026-08-18 | Decided | `docs/adr/0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md` |
| 12 | Secret reveal moves into a conditionally-rendered modal (plaintext never in the DOM while closed), Value column deleted outright, copy buttons icon-only with the label as a daisyUI tooltip; partially supersedes #11's map/re-stream mechanics | 2026-08-18 | Decided | `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md` |
| 13 | Secret edit lives inside the reveal modal via content-swap-in-place (no second `<.modal>`), gated on `socket.assigns.revealed` matching `%Secret{key: ^key}`; `Nucleus.Secrets.Value` and an `embedded_schema` edit form set the pattern `SEC-S6` reuses | 2026-08-18 | Decided | `docs/adr/0013-secret-edit-in-modal-and-value-form.md` |
| 14 | Secret creation — one consolidated `Nucleus.Secrets.Key.validate/1` (denylist, no casing rule, `Error.t()` shape matching `Value`), `create/4` relies on the store's atomic `:already_exists` refusal, and the creation modal is mutually exclusive with the reveal modal to structurally avoid ADR-0012's `focusStack` double-pop | 2026-08-19 | Decided | `docs/adr/0014-secret-creation-key-consolidation-and-modal-exclusion.md` |
| 15 | Shared AWS identity seam — two independent role ARNs (`TENANT_ROLE_ARN`, EN-10's `COGNITO_ROLE_ARN`), credential cache keyed on `{role_arn, external_id, session_name}` not the caller, region parameterised now with the second variable and its wiki amendment deferred to EN-10 | 2026-08-19 | Decided | `docs/adr/0015-shared-aws-identity-seam.md` |
| 16 | M2M client adapter — derived OAuth scope (no new config var), operator-chosen token validity (5–60 min, stored in seconds), bounded fan-out with degrade-not-fail listing; `M2M-A09` removed mid-implementation — Cognito does not enforce client-name uniqueness | 2026-08-19 | Decided | `docs/adr/0016-m2m-client-adapter.md` |
| 17 | M2M naming, deny-list, and resolution gate — `M2M_DENY_SUFFIXES` defaults to the prototype's Terraform value (fail-closed, `none` sentinel), `ClientId` uses AWS's own `[\w+]+` pattern not a tighter one, tenancy is the full `{tenant}-control-plane-` prefix (pool shared across tenants), deny-list enforced at creation too — new wiki action `M2M-A18` | 2026-08-19 | Decided | `docs/adr/0017-m2m-naming-deny-list-and-resolution-gate.md` |
| 18 | M2M clients listing — two `Phoenix.LiveView` modules (`Index`/`Show`, the `phx.gen.live` split) not one switching on `handle_params/3`; `Nucleus.M2M.list/1` collapses the deny-list gate to one call, reusing `visible?/1`; row DOM ids are the plain `client_id` (already allowlist-safe, unlike Secrets' ARN hash); create button sits outside the empty-state conditional | 2026-08-20 | Decided | `docs/adr/0018-m2m-clients-listing-module-split-and-dom-ids.md` |
| 19 | M2M client detail — `Show.mount/3` calls `fetch/2` (no audit) disconnected and `view/2` (audit) only once `connected?(socket)`, so `m2m_client_viewed` fires exactly once per open with no render flicker; `TokenValidity.humanize/1` corrected to the actual three-tier, seconds-based `M2M-A16` rule over the issue's stale hours-only draft; `Format.created_date/1` extracted so `Index`/`Show` share one formatter | 2026-08-20 | Decided | `docs/adr/0019-m2m-client-detail-mount-audit-guard-and-token-validity.md` |
| 20 | M2M client creation — `create/4` (not the plan's stale `create/3`) threads `token_validity_minutes` through to `Clients.create_client/2`'s own structural range guard; `DenyList.suffixes/0` checked before `denied?/1` (a fail-open ordering bug caught in review, now pinned by a test); the one-time credentials panel is deliberately not `<.modal>` (no backdrop/Escape dismissal); re-lists on success and clears `:credentials` on reopen, reusing ADR-0014's patterns | 2026-08-24 | Decided | `docs/adr/0020-m2m-client-creation-and-credentials-panel.md` |
| 21 | M2M secret rotation — `rotate/2` mirrors `create/4`'s shape (resolves through `fetch/2`, audits on success only); `CredentialsPanel` gains a `title` attribute rather than forking for rotation's wording; a failed rotation's `:unavailable` kind stays local (`#rotate-secret-error`, "reload and check") rather than collapsing to the shared page-replacing `States.unavailable/1`, since Cognito's rotate sequence can partially apply; retry means re-confirming, not a second control that skips `M2M-A12` | 2026-08-25 | Decided | `docs/adr/0021-m2m-secret-rotation-and-unavailable-copy.md` |
| 22 | Nomad jobs adapter — `Job.Version` from the detail response not `Meta.version`; periodic run count dropped entirely; image from the `Lifecycle == nil` task not `Tasks[0]`; `ParentID` filtering covers dispatch children too; cron reads `Periodic.Specs \|\| Periodic.Spec`; one `detail_error` field covers all three detail-sourced fields; `:nomad_jobs` kept distinct from wiki `ADR-0007`'s single `NOMAD_BACKEND`; async load with a ~15s overall budget plus a 10s per-request timeout | 2026-08-25 | Decided | `docs/adr/0022-nomad-jobs-adapter.md` |
| 23 | Sidebar environment grouping — `NucleusWeb.SidebarEnvironments.group/1` (not `EnvironmentsHook`) now owns archived-exclusion, unit-tested directly; per-category expand/collapse is a socket assign toggled via `Phoenix.LiveView.attach_hook/4` on `:handle_event` (this codebase's first use), not client-side `JS`, since `Layouts.app` is a function component shared across four LiveViews and the toggle must be provable via `render_click/1`; corrected post-review — `with_slugs/1` disambiguates category names that collapse to the same DOM-id slug (e.g. `"Prod East"` vs `"Prod-East"`), which `group/1` treats as distinct but `slug/1` alone did not | 2026-08-25 | Decided | `docs/adr/0023-sidebar-environment-grouping-and-category-toggle-state.md` |
| 24 | Sidebar expand/collapse survives navigation — `NucleusWeb.SidebarNavState` (a supervised `GenServer` owning a `:protected` ETS table) backs `:expanded_categories` instead of a plain assign, since `<.link navigate>` always remounts `EnvironmentsHook`'s `on_mount`, even to the same LiveView module; keyed by a random `nav_session_id` (`AssignScope`), not `current_scope`, since auth is deferred and every request shares one dev identity; reads bypass the `GenServer` (`:ets.lookup/2` direct), writes go through it (`GenServer.call/2`) so concurrent same-session toggles cannot lose an update | 2026-08-25 | Decided | `docs/adr/0024-sidebar-expand-state-survives-navigation.md` |
| 25 | Applications listing — one `NucleusWeb.ApplicationsLive` module, bounding `docs/adr/0018`'s Index/Show split to *match the module count to the route count* (no detail route here); row and cell DOM ids derive from the unhashed `Job.name`, resolving the ticket's unreferenced `#job-{id}-*` contract to `name` — safe **only** because `Job.child?/1` filters `/`-bearing child names out at the boundary, since `Job.name` has no validating allowlist and LazyHTML rejects a `/` in a selector outright; the name-ascending sort stays in the LiveView rather than expanding `list/1`'s contract; version/image/schedule ship as empty cells at their final ids so `APP-S2` is content-only | 2026-08-26 | Decided | `docs/adr/0025-applications-listing-single-module-and-name-derived-dom-ids.md` |
| 26 | Applications row formatters — shared `NucleusWeb.Nomad.JobFormat` (`status_class/1`, `status_text/1`, `version_text/1`, `image_text/1`, `schedule_text/1`) over `Job.t()`, unblocking DEX-S5; `detail_error` degrades version/image/schedule text identically, including a degraded periodic job's cron; status badge is a `<span>` nested in the `#job-{name}-status` cell (id moves onto the span), `align-middle` on the `<td>` so the pill centers vertically in the row; Version column retitled "Job revision"; rendered status colour (not the CSS class) recorded as a `test/README.md` gap, following `M2M-A10`/`SEC-A04`'s precedent of not reopening `docs/adr/0008` itself | 2026-08-26 | Decided | `docs/adr/0026-applications-row-formatters-and-status-colour-test-gap.md` |

No **"re-platform" decision** (fresh start) and no **inherited ADRs** — the wiki's `ADR-0001`–
`ADR-0007` are reference only; adopting one is a decision made on its own merits.

**Next decision likely needed** (`living-notes.md`): how a real token is held/refreshed across a
live socket — narrowed by EN-6 to a fixed `Nucleus.Scope.token` field, open on *how*.

## Deprecated Decisions

Row **11**'s reveal *mechanics* are partially superseded by row 12 (2026-08-18): `:revealed` is a
single `Secret` rather than a `%{key => Secret.t()}` map, and a reveal or hide no longer calls
`stream_insert/3` because no row markup depends on reveal state. Row 11 keeps its number and its
ADR — its `SecretRef`-only stream guarantee, its `Scope.audit_user/1` decision, and its `$callers`
sink fallback all still stand. Read `0011` then `0012`, in that order.

A wholly overturned decision is recorded here in full: the decision, the date, what replaced it,
and why. A superseded row keeps its number and moves here rather than being edited in place, so
the ADR it points at stays findable.

## Onboarding Checklist

- [ ] Read the Decision Index above; `adr/0001`–`0026` are binding
- [ ] New formal ADRs belong in `docs/adr/`, with only an index row mirrored here — the wiki's
      ADR-0001–0007 are reference only, not adopted
- [ ] Know which decisions are pending (see `living-notes.md`)

## Related Files

- `technical-domain.md` - Technical implementation affected by these decisions
- `business-tech-bridge.md` - How decisions connect business and technical
- `living-notes.md` - Current open questions that may become decisions
- `docs/adr/` - Formal ADR documents for this project, with full context/rationale/alternatives
