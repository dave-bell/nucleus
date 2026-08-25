<!-- Context: project-intelligence/notes | Priority: high | Version: 1.17 | Updated: 2026-08-24 -->

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
| No browser-driven test coverage for `SEC-A02` (the `navigator.clipboard.writeText` call itself, the confirmation face swap/revert — an icon in a row, the word "Copied" in the modal — the non-secure-context `execCommand` fallback, the failure indication, and the hover/`:focus-visible` reveal of any tooltip, now on path and ARN values as well as the copy buttons) or for modal dismissal — `SEC-A13`'s focus trap and focus restoration (both the reveal modal's and the create modal's), plus `SEC-A04`'s Escape and backdrop-click routes, which reach the server only by running the `JS` chain in `data-cancel`. `M2M-A04`–`A07`'s create modal (M2M-S4/#37) has the identical gap — Escape, backdrop click, focus trap/restoration, and typing-lag are all client-side. `M2M-A08`'s one-time credentials panel (M2M-S5/#38) has the clipboard-write half of the same gap for its own two copy buttons, plus focus trap/restoration — but *not* the Escape/backdrop half, since that panel deliberately carries no `data-cancel`/`phx-click-away`/`phx-window-keydown` wiring at all (see `NucleusWeb.M2MClientsLive.CredentialsPanel`'s moduledoc) | Tests assert wiring only (hook attached, `data-value` full/untruncated, `phx-update="ignore"` present, `data-tip` set, `on_cancel`/`phx-key`/`phx-click-away` present), and claim `@tag action:` for `SEC-A04`/`SEC-A13`/`M2M-A04`–`A07`/`M2M-A08` **only** via each modal's plain-`phx-click` dismiss control (Close, Cancel, the credentials panel's own explicit dismiss), which `render_click/1` can actually drive | Medium | Add Wallaby once sign-in exists (deferred, EN-8); see `docs/adr/0008-test-strategy.md`. Five gap sets are skipped `:browser`-tagged placeholder modules — `secrets_live_test.exs`'s `CopyButtonBrowserGaps` (4), `SecretRevealModalBrowserGaps` (5), and `NewSecretModalBrowserGaps` (5), and `m2m_clients_live_test.exs`'s `NewClientModalBrowserGaps` (5) and `CredentialsPanelBrowserGaps` (7) |
| `LOCAL_FORCE_ERROR` (`Nucleus.Backend.Faults`) is node-global, not per-boundary — a fault set for one boundary is seen by every local implementation's next call | A test targeting the `:secrets` boundary's error path is actually caught by whichever boundary is called first; SEC-S2 found this when `Nucleus.Secrets.list/2`'s `Environments.fetch/2` gate always intercepted the fault before `Store.list_secrets/1` ran | Low | Swap in a real/failing module via `Application.put_env(:nucleus, :backends, ...)` instead of `force_error/2` for a specific-boundary test — see `SecretsLiveTest.FailingSecretsStore` |

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
- Where a dismissal control must be provable in `Phoenix.LiveViewTest`, give it a plain
  `phx-click="event"` rather than a `JS.exec("data-cancel", ...)` chain — `render_click/1` can
  drive the former and not the latter. The modal's `phx-remove` still runs `hide_modal/2`, so
  focus restoration is unaffected. See `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md`.
- `Nucleus.Audit.Sink.Test` falls back to `Process.get(:"$callers")` when the writing process
  has no direct `register/1` call — reaches a test's own `AuditCase` registration from inside a
  mounted LiveView, using the same ancestry chain Ecto's SQL Sandbox relies on. Any test
  asserting on an audit event emitted from a `handle_event/3` gets this for free; no per-ticket
  sink workaround needed. See `docs/adr/0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md`.
- A LiveView form backed by a tiny `embedded_schema` + `Ecto.Changeset`, one module per form
  (`NucleusWeb.SecretsLive.EditForm`), with shape validation (length, emptiness) delegated to a
  plain function (`Nucleus.Secrets.Value.validate/1`) via `validate_change/3` — so the inline
  error shown while typing and the error the context function returns on submission are the same
  text, defined once. `SEC-S6`'s creation form is expected to follow this shape and reuse
  `Value.validate/1` rather than invent a second copy. See
  `docs/adr/0013-secret-edit-in-modal-and-value-form.md`.
- Swap a modal's *content* in place (an `:editing`-style boolean toggling which `~H` block
  renders inside one already-open `<.modal>`) rather than stacking a second `<.modal>` over the
  first — sidesteps ADR-0012's `focusStack`/`JS.pop_focus/1` double-pop risk entirely instead of
  needing a fix for it. See `docs/adr/0013-secret-edit-in-modal-and-value-form.md`.
- A denylist validator returning `Nucleus.Backend.Error.t()` with the specific reason carried in
  `error.details.reason` (`Nucleus.Secrets.Key`), matching a sibling shape validator
  (`Nucleus.Secrets.Value`) that returns the same struct — two validators feeding the same
  `with` chain (`Nucleus.Secrets.create/4`) need no special case for either one's failure, and a
  form layer that needs distinct per-rule copy (`SEC-A10`) reads `error.message` directly rather
  than pattern-matching a bare atom. See `docs/adr/0013-secret-edit-in-modal-and-value-form.md`'s
  addendum.

### Gotchas for Maintainers
- **Requirements are a submodule.** Fresh clones need
  `git submodule update --init --recursive`, or `docs/requirements/` will be empty.
- **Don't copy requirement text into context files.** Cite the action ID.
- **The wiki's `API:` lines are not routes.** Building a REST layer to satisfy them adds a
  surface no requirement asked for.
- **`mix precommit` is the required gate** before finishing any change (see `AGENTS.md`).
- **`LazyHTML.query/2` returns a `%LazyHTML{}` struct, not a list.** `assert LazyHTML.query(doc,
  sel) != []` is therefore *always* true and proves nothing — several `SEC-A02` guards were
  vacuous for exactly this reason until ADR-0012's change caught it. Use
  `refute Enum.empty?(LazyHTML.query(doc, sel))`. `LazyHTML.attribute/2` **does** return a plain
  list, so `== ["ignore"]` and `== []` on an attribute result are fine.
- **A conditionally-rendered modal runs `JS.pop_focus/1` twice** on any dismissal route that
  goes through `data-cancel` (the X, Escape, a backdrop click): once client-side from
  `JS.exec("phx-remove")`, then again when the server removes the element and `phx-remove` fires
  for real. Harmless while one modal is open — the second pop finds an empty `focusStack` and
  no-ops — but `focusStack` is module-global, so **two modals open at once would have the inner
  one consume the outer one's saved focus**. `NucleusWeb.SecretsLive` now has two independently
  conditionally-rendered modals (reveal, `SEC-S4`/ADR-0012; create, `SEC-S6`) and resolves this by
  **mutual exclusion, not a fix to the interaction itself**: opening either one
  (`"reveal"`/`"new_secret"`) resets the other's assigns to its closed state in the same step, so
  the two are never both mounted at once as a structural guarantee. Reaching for a third
  conditionally-rendered modal in this LiveView means extending that mutual-exclusion set, not
  assuming the existing pair already covers it. See
  `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md`.
- **`CoreComponents.modal/1` has two legitimate usages, and the wrong one leaks.** Left mounted
  and toggled with `modal-open`, its inner block is in the DOM (and in view-source) while the
  dialog is closed — fine for a form, a leak for secret material. Anything sensitive wraps the
  `<.modal>` in a server-side `:if` and passes `show={true}`, as `NucleusWeb.SecretsLive`'s
  reveal modal does. See `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md`.

## Active Projects

*(none currently — `mix nucleus.trace` shipped via EN-8; see Archive)*

## Archive (Resolved Items)

Moved here for historical reference.

**`Nucleus.Secrets.reveal/3`'s key validator was a second, weaker copy of `Environments.validate_name/1`'s deny-list** — *was: Technical Debt, Low*
*Resolved*: 2026-08-19 by SEC-S6 (issue #14).
*Outcome*: Consolidated into `Nucleus.Secrets.Key.validate/1` — the one key validator in the
application, shared by `reveal/3`, `update/4`, and the new `create/4` (`SEC-A09`). Same denylist
(`..`, `/`, `\`, null byte, empty, over 256 characters), now with a distinct reason atom per rule
in `error.details.reason` (`SEC-A10`'s "the form indicates the specific problem"), and a
deliberate decision to add **no casing rule** — considered and rejected, since a create-only
casing constraint would route a rejected legitimate key around Nucleus entirely rather than
through its audit trail. The 256-character cap now applies to the read path too, documented as a
deliberate consequence rather than left to be discovered.
*See*: `docs/adr/0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md`,
`docs/adr/0013-secret-edit-in-modal-and-value-form.md`'s addendum, and SEC-S6's own ADR.

**`SEC-S5`'s plan (issue #13) was stale under ADR-0012** — *was: Technical Debt, Medium*
*Resolved*: 2026-08-18 by SEC-S5 (issue #13).
*Outcome*: Gated on `socket.assigns.revealed` matching `%Secret{key: ^key}`, not a map lookup.
The edit affordance moved inside the reveal modal, swapping its content in place rather than
stacking a second `<.modal>` — which also sidesteps ADR-0012's `focusStack` double-pop risk
entirely instead of needing a fix for it. `SEC-A07`'s re-masking came free with `:revealed` going
to `nil` on save success, exactly as ADR-0012 predicted.
*See*: `docs/adr/0013-secret-edit-in-modal-and-value-form.md`

**`NucleusWeb.SecretsLive` was a placeholder** — *was: Technical Debt, Medium*
*Resolved*: 2026-08-14 by SEC-S1 (issue #9); listing added 2026-08-17 by SEC-S2 (issue #10).
*Outcome*: Replaced wholesale, as ADR-0006 always intended. `Nucleus.Secrets.list/2` now gates
through `Nucleus.Environments.fetch/2` in one call and lists a `Nucleus.Secrets.Store`
boundary's secrets (`SEC-A01`, `SEC-A14`); every `Nucleus.Backend.Error` kind across both
boundaries renders without crashing.
*See*: `docs/adr/0009-environment-validation-ladder.md`, `docs/adr/0010-secrets-listing-gate-collapse-and-dom-ids.md`

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
