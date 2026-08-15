<!-- Context: project-intelligence/notes | Priority: high | Version: 1.7 | Updated: 2026-08-14 -->

# Living Notes

> Active issues, technical debt, open questions, and insights that don't fit elsewhere. Keep this alive.

## Quick Reference

- **Purpose**: Capture current state, problems, and open questions
- **Update**: Weekly or when status changes
- **Archive**: Move resolved items to bottom with status

## Technical Debt

| Item | Impact | Priority | Mitigation |
|------|--------|----------|------------|
| `docs/adr/` had no ADRs while 7 prototype ADRs sit in the wiki | ADR-shaped questions get answered in chat and lost | Medium | Write this project's own ADRs as decisions land — `0001` now exists |
| LiveDashboard at `/dev/dashboard` unauthenticated | Fine in dev; a leak if ever exposed in prod | Medium | Gate behind auth before any production deploy |
| Nucleus's own AWS identity (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`) is read ambiently by the `aws` package, with no boot-time check or ops-facing doc — unlike `TENANT_ROLE_ARN`/`AWS_REGION`/`CLUSTER_NAME`/`DEPLOYMENT_NAME`, which all raise at boot | A misconfigured deployment fails per-request as `:not_configured` on first `AssumeRole` call, not at boot | Low | `CLUSTER_NAME`/`DEPLOYMENT_NAME` are now correctly documented in the wiki's `Platform-Operations.md` config reference (issue #22). The ambient `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` doc gap remains open — was out of scope for #22 |
| No browser-driven test coverage for `SEC-A02` (clipboard write confirmation) or `SEC-A13` (Escape dismissal, focus trap, focus restoration) — `navigator.clipboard` and real key/focus events need a browser, which this repo has no driver for | Tests assert wiring only (hook attached, `on_cancel` set), never claim `@tag action:` for these IDs — a real regression would not be caught until a browser harness exists | Medium | Add Wallaby once sign-in exists (deferred, EN-8); see `docs/adr/0008-test-strategy.md` |

### Technical Debt Details

*(no open debt details — the `Nucleus.Repo` item was resolved by EN-1; see Archive)*

## Open Questions

| Question | Stakeholders | Status | Next Action |
|----------|--------------|--------|-------------|
| How does token passthrough work over a LiveView socket? | Tech lead, security | Open | Design spike against `AUTH-*` and `SEC-A18` |
| Do the wiki's `AUTH-A01`–`A11` still describe the intended flow? | Product, tech lead | Open | Review the 11 actions against a LiveView design |
| Where does Nucleus deploy, and via what CI? | Ops | Open | Confirm target; no CI exists in this repo |
| Should `mix nucleus.trace` gate `precommit`? | Tech lead | Open | Report-only since EN-8; revisit once Secrets (`SEC-*`) is complete — gating now would block every open SEC ticket |

### Open Question Details

**Token passthrough across a long-lived LiveView socket**
*Context*: Token passthrough is a binding constraint — Nucleus forwards the signed-in user's
own access token so their permissions apply end-to-end. This is straightforward in a
request/response API. It is materially harder in LiveView, where a stateful WebSocket
outlives the HTTP request that authenticated it. The token must be carried into the socket,
kept out of assigns that get diffed to the client, and refreshed or failed cleanly when it
expires mid-session. The requirements already anticipate the expiry case in `SEC-A18`
("session has expired, ask to re-authenticate, retry succeeds").
*Stakeholders*: Tech lead, security reviewer
*Options*: (a) token in the signed session, read at `on_mount`, re-verified per backend call;
(b) short-lived token in socket state with an explicit refresh path; (c) a per-user
server-side credential holder process — note (c) is in tension with the stateless constraint.
*Timeline*: Blocks all three backend integrations; needed before the first feature LiveView.
*Status*: Open — narrowed again by EN-6. `Nucleus.Scope` (`lib/nucleus/scope.ex`) now carries
a `token` field, always `nil` while auth is disabled, and `NucleusWeb.Plugs.AssignScope`
defensively forces `token` to `nil` before writing the scope into the session regardless of
what a provider returns — a floor, not an answer. Which of options (a)/(b)/(c) above actually
holds the token once one is real, and how it survives a socket reconnect, is still open and
deferred to the real auth ticket. See `docs/adr/0005-deferred-authentication.md`.

**Do the wiki's `AUTH-*` actions still describe the intended flow?**
*Context*: `Authentication-and-Access.md` defines `AUTH-A01`–`A11`. These were written against
the earlier prototype's redirect-and-API-call flow. Cognito Hosted UI federated to the
corporate IdP is still the intended entry point, but session lifecycle and sign-out behaviour
over a LiveView socket may not match action-for-action. Unlike other pages, where only the
`API:` line is transport-specific, here the *behaviour itself* may differ.
*Stakeholders*: Product owner, tech lead
*Options*: Re-verify each of the 11 actions; amend the wiki where LiveView genuinely differs.
Amend the wiki — do not silently reinterpret, since the wiki is the binding source.
*Timeline*: Before implementing authentication.
*Status*: Open — EN-6 built the `Nucleus.Scope`/`Nucleus.Scope.Provider` seam against the
current eleven actions without re-verifying them, and deliberately implements none of
`AUTH-A01`–`A11` (no `@tag action:` in its tests) so `mix nucleus.trace` cannot report false
coverage. Re-verification is still needed before the real auth ticket, not before this one.

## Known Issues

| Issue | Severity | Workaround | Status |
|-------|----------|------------|--------|
| `context-indexer` agent fails: `Model not found: haiku/.` | Low | Do the coverage check manually | Known |

### Issue Details

**`context-indexer` subagent is misconfigured**
*Severity*: Low
*Impact*: Context-system tooling that delegates to `context-indexer` fails immediately. Does
not affect application code.
*Reproduction*: Invoke the `context-indexer` subagent; it returns `Model not found: haiku/.`
*Root Cause*: The agent definition in `.opencode/agents/context-indexer.md` references a
model alias that does not resolve in this environment.
*Fix Plan*: Correct the model reference in the agent definition, or the `apm` package that
deploys it.
*Status*: Known

## Insights & Lessons Learned

### What Works Well
- Stable, never-renumbered action IDs in the wiki — they survive refactors and make
  requirement-to-test traceability mechanical rather than manual.
- GitHub wikis are git repos, so requirements can be pinned as a submodule instead of being
  copied into the repo and left to rot.

### What Could Be Better
- The wiki mixes binding requirements with an obsolete architecture in the same pages, so
  readers must know which sections to ignore. `business-tech-bridge.md` documents the split.

## Patterns & Conventions

### Code Patterns Worth Preserving
- `@tag action: "SEC-A03"` on tests, enabling `mix test --only action:SEC-A03` — see
  `business-tech-bridge.md`.
- Stack `on_mount` hooks at the `live_session` level, in a fixed order, when one hook's
  assign depends on another's (`EnvironmentsHook` reads `current_scope.token` after
  `ScopeHook` assigns it) — see `docs/adr/0006-application-shell-and-live-session-composition.md`.
  Keeps every view under the session correct without each one opting in individually.

### Gotchas for Maintainers
- **Requirements are a submodule.** Fresh clones need
  `git submodule update --init --recursive`, or `docs/requirements/` will be empty.
- **Don't copy requirement text into context files.** Cite the action ID.
- **The wiki's `API:` lines are not routes.** Building a REST layer to satisfy them adds a
  surface no requirement asked for.
- **`mix precommit` is the required gate** before finishing any change (see `AGENTS.md`).

## Active Projects

*(none currently — `mix nucleus.trace` shipped via EN-8; see Archive)*

## Archive (Resolved Items)

Moved here for historical reference.

**`NucleusWeb.SecretsLive` was a placeholder** — *was: Technical Debt, Medium*
*Resolved*: 2026-08-14 by SEC-S1 (issue #9).
*Outcome*: Replaced wholesale, as ADR-0006 always intended. Validates the environment in
`handle_params/3` via `Nucleus.Environments.fetch/2` and renders one of three fail-closed
states (`SEC-A15`–`A17`); renders no secrets UI of its own yet — that is `SEC-S2` onward.
*See*: `docs/adr/0009-environment-validation-ladder.md`

**Build `mix nucleus.trace`** — *was: Active Project*
*Resolved*: 2026-08-14 by EN-8 (issue #8).
*Outcome*: `mix nucleus.trace` diffs `### PREFIX-A##` headers in `docs/requirements/*.md`
against `@tag action:` claims in `test/`, reporting covered/uncovered/claimed-but-undefined.
Supports `--feature`/`--exitcode`; deliberately report-only, not wired into `precommit` — see
the open question above.
*See*: `docs/adr/0008-test-strategy.md`

**`Nucleus.Repo` / Postgres was generator scaffolding** — *was: Technical Debt, High*
*Resolved*: 2026-08-07 by EN-1 (issue #1).
*Outcome*: Removed `ecto_sql`, `postgrex` and `Nucleus.Repo` entirely — supervision tree,
`priv/repo/`, all four config files, the `CheckRepoStatus` plug, the dead
`nucleus.repo.query.*` telemetry metrics, and the test sandbox plumbing. **`ecto` and
`phoenix_ecto` were deliberately retained** for `embedded_schema` + `Ecto.Changeset` form
validation, which needs no database. Note this differs from the original proposed solution
above, which suggested dropping `phoenix_ecto` too.
*See*: `docs/adr/0001-no-local-datastore.md`

**Keep Ecto/Postgres, or honour stateless strictly?** — *was: Open Question*
*Resolved*: 2026-08-07 by EN-1 (issue #1).
*Outcome*: Honour stateless strictly. The constraint is now structurally enforced — adding a
datastore requires adding a dependency and configuration, a visible and reviewable act.
*See*: `docs/adr/0001-no-local-datastore.md`

## Onboarding Checklist

- [ ] Review known technical debt and understand impact
- [ ] Know the open questions, especially token passthrough
- [ ] Initialise the `docs/requirements/` submodule
- [ ] Be aware of the gotchas above
- [ ] Know that `mix precommit` must pass before finishing

## Related Files

- `decisions-log.md` - Past decisions that inform current state
- `business-domain.md` - Business context for current priorities
- `technical-domain.md` - Technical context for current state
- `business-tech-bridge.md` - Context for current trade-offs
