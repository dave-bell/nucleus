# ADR-0020: M2M Client Creation and the One-Time Credentials Panel

## Status

Accepted — 2026-08-24

Decided on [M2M-S5](https://github.com/dave-bell/nucleus/issues/38). Builds on
`0016-m2m-client-adapter.md` (EN-10's `Clients.create_client/2`, the
structural 5–60 minute token-validity guard this ticket relies on rather
than duplicating), `0017-m2m-naming-deny-list-and-resolution-gate.md`
(`DenyList.denied?/1`, exposed standalone specifically for this ticket's
creation-time guard), `0012-secret-reveal-modal-and-icon-only-copy-affordances.md`
(the conditionally-rendered-modal shape and the `focusStack` hazard this
ticket's panel avoids), and `0014-secret-creation-key-consolidation-and-modal-exclusion.md`
(the re-list-on-create and mutual-exclusion patterns this ticket reuses
rather than re-deriving).

## Context

M2M-S5 implements `M2M-A08` (create a client, reveal its ID and secret
exactly once) and `M2M-A18` (reject a reserved name before any adapter
call). Three things the ticket's own plan text got wrong or left open,
discovered before and during implementation rather than decided on the
issue thread beforehand:

1. **The plan's own `@spec` for the create function was stale.** It typed
   `create(ticket_id, purpose, scope)` — no token-validity parameter — but
   a later issue comment (resolving EN-10's Decision 4) says
   `create_client/2` "now takes `token_validity_minutes` (5–60) from the
   form built in #37," and that this slice claims `M2M-A17`'s range check
   through that same call. The two statements are only consistent if the
   create function's arity grew to carry the value from M2M-S4's form
   through to `Clients.create_client/2`.
2. **A fail-open ordering bug, caught in review, not in the plan.**
   `Nucleus.M2M.DenyList.denied?/1` fails closed (returns `true`) when the
   deny-list itself is unreadable — correct for that function taken alone,
   since `fetch/2` always checks `DenyList.suffixes/0` directly first and
   never reaches `denied?/1` on that branch. A first implementation of this
   ticket's own creation-time guard called `denied?/1` without that same
   `suffixes/0` check ahead of it, which meant an unconfigured
   `M2M_DENY_SUFFIXES` rejected *every* creation attempt as
   `:reserved_name` — an ops misconfiguration reported as if the operator
   had chosen a bad purpose, and the wrong `Nucleus.Backend.Error.kind`
   besides.
3. **The plan asked for a panel that is not, in the details, `<.modal>`.**
   `M2M-A08` requires the operator be able to copy both values *before
   leaving the screen*, and the plan itself says: "do not... close it on an
   incidental click elsewhere." `NucleusWeb.CoreComponents.modal/1` wires
   exactly that incidental dismissal — backdrop click and Escape both route
   through the same `data-cancel` chain as its own close button — which is
   the right behaviour for a form and the wrong one for a secret shown
   exactly once.

## Decision

### `Nucleus.M2M.create/4`, not `create/3`

`create(ticket_id, purpose, token_validity_minutes, scope)`. The fourth
argument is the value M2M-S4's form collects; `Clients.create_client/2`
already enforces `M2M-A17`'s 5–60 minute range structurally
(`docs/adr/0016-m2m-client-adapter.md`), so this function does not
duplicate that check — it only has to thread the value through and let the
adapter's own guard produce `{:error, %Error{kind: :invalid}}` on an
out-of-range value, which the LiveView then attaches to
`:access_token_validity_minutes` as a form error. `M2M-A17`'s test tag is
claimed through this call, not a second copy of the range check.

### Strict order: `suffixes/0` before `denied?/1`, not `denied?/1` alone

```elixir
with :ok <- validate_field(:ticket_id, TicketId.validate(ticket_id)),
     :ok <- validate_field(:purpose, Purpose.validate(purpose)),
     client_name = ClientName.build(ticket_id, purpose),
     {:ok, _suffixes} <- DenyList.suffixes(),
     :ok <- reject_if_denied(client_name),
     {:ok, credentials} <- Clients.create_client(client_name, token_validity_minutes: token_validity_minutes) do
  ...
end
```

Mirrors `fetch/2`'s own step 2 exactly, for the reason given in Context
above: `denied?/1`'s fail-closed default exists for this call site
specifically (per `docs/adr/0017-m2m-naming-deny-list-and-resolution-gate.md`'s
own "Negative consequences" note that the branch was otherwise
unreachable), and skipping the direct `suffixes/0` check in front of it
turns "deny-list unreadable" into "every name is reserved," which is a
worse failure than either bare kind alone. Pinned by a dedicated test
(`test/nucleus/m2m_test.exs`) alongside `fetch/2`'s own equivalent case,
so the two cannot silently drift back apart.

### The credentials panel is not `<.modal>`

`NucleusWeb.M2MClientsLive.CredentialsPanel.credentials_panel/1` renders its
own backdrop-and-box markup, `focus_wrap/1`, and `JS.push_focus/1`/
`JS.pop_focus/1` on mount/remove — everything `modal/1` gives for
accessibility — but carries no `phx-click-away` and no
`phx-window-keydown`. The only way out is its own explicit dismiss button.
This is a deliberate, narrow divergence from `modal/1`'s established shape,
scoped to this one component: every other modal in the app (the creation
form, the reveal modals in Secrets) legitimately treats a backdrop click or
Escape as "the user is done here," and this is the one place that
assumption is false — a stray Escape while reaching for the copy button
must not silently discard the only copy of a secret whose only recovery is
rotation.

Reused verbatim by M2M-S6 (#39, rotation) rather than rebuilt, per the
ticket's own instruction — placed under `lib/nucleus_web/live/m2m_clients_live/`
alongside `Format` and `States`, following M2M-S2's Decision 7 precedent
that a component two modules need in common is a real shared module, not a
copy-paste starting point.

### Re-list on success, mirroring ADR-0014's choice for Secrets

`save_new_client`'s success path calls `fetch_clients/1` (which wraps
`Nucleus.M2M.list/1`) rather than computing a `stream_insert/3` position
from the submitted name. `Nucleus.M2M.list/1` already sorts
case-insensitively with a raw-name tiebreak (`docs/adr/0018-m2m-clients-listing-module-split-and-dom-ids.md`);
re-deriving that ordering a second time here risks the two drifting apart
silently, the same reasoning ADR-0014 recorded for `Nucleus.Secrets.create/4`.
Re-listing cannot drift because it *is* `list/1`, and it refreshes
`:client_count` in the same step, which is what flips the empty state to
the table on a first client with no separate code path.

### Mutual exclusion between the creation modal and the credentials panel

Opening the creation modal (`handle_event("new_client", ...)`) clears
`:credentials` to `nil` in the same step. Both the panel and `<.modal>`
push onto the same module-global `focusStack`
(`JS.push_focus/1`/`JS.pop_focus/1`); having both mounted at once would
double-pop it on whichever closes second — exactly the hazard
`docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md`
predicted and `docs/adr/0014-secret-creation-key-consolidation-and-modal-exclusion.md`
fixed structurally for Secrets' own two conditionally-rendered modals. A
fresh "New client" click after a successful create discards an unretrieved
secret exactly as visibly as any other abandonment — the operator sees the
form open and the panel gone, not a silent loss.

### Failure copy: field errors for the two `M2M-A18`/format cases, a banner for the rest

A `:reserved_name` rejection attaches a changeset error to `:purpose`
(the field a reserved suffix is actually reachable through — see
`docs/adr/0017-m2m-naming-deny-list-and-resolution-gate.md`'s note that
five of six configured suffixes are only reachable as a purpose, never a
ticket ID). `:not_configured`, `:unavailable`, and `:auth_expired` render
as a `:create_error` banner above the modal's action row, reusing this same
module's own page-level copy for the latter two — mirroring
`NucleusWeb.SecretsLive`'s `create_error_message/1` pattern exactly, rather
than inventing a third copy convention. Every branch reassigns
`:create_form` from the submitted (not a fresh empty) changeset, including
the generic fallback branch — entered values are never discarded on
failure, on any branch.

## Consequences

### Positive

- The deny-list ordering bug is now structurally pinned by a test
  (`"an unconfigured deny-list returns :not_configured, not
  :reserved_name..."`) rather than only fixed once and left to regress.
- `M2M-S6` (#39) inherits a working, documented credentials panel with no
  component work of its own — the same "no second modal shape to
  rediscover" benefit ADR-0012's reveal modal gave `SEC-S6`.
- `Nucleus.M2M.create/4`'s signature makes a caller-supplied client name
  structurally impossible to inject: there is no parameter for one, and the
  name is built once, server-side, from the two validated inputs every
  caller must supply.
- No second, independently-written deny-list check exists for the write
  path — `denied?/1` is called standalone, exactly as
  `docs/adr/0017-m2m-naming-deny-list-and-resolution-gate.md` anticipated,
  with the same ordering discipline as the read path now enforced by a test
  rather than only by convention.

### Negative

- `Nucleus.M2M.create/4`'s arity now disagrees with the number the ticket
  body's plan text used (`create/3`). Anyone reading the closed issue
  literally, without this ADR, would look for a function that does not
  exist.
- The wiki's own audit table for `m2m_client_created` lists
  `token_validity_minutes` as a field; `lib/nucleus/audit/event.ex`'s actual
  allowlist only has `client_name` and `ticket_id`. This ticket followed the
  code catalogue, per the ticket body's own explicit instruction to do so —
  the wiki table is now the stale side of that pair, and updating it is not
  part of this ticket's scope. Left as a known drift, not fixed here.
- `CredentialsPanel`'s no-backdrop/no-Escape design is a component-level
  exception to `modal/1`'s otherwise-universal dismissal convention. A
  future modal built by copying this one instead of `modal/1` would inherit
  the exception without necessarily needing it — mitigated only by the
  component's own moduledoc stating the reason plainly.

## Alternatives considered

**Keep `create/3` and pass `token_validity_minutes` some other way (a map,
a fourth positional field folded into `scope`).** Rejected — `scope`
carries caller identity/tenancy, not form data, and overloading it would
blur that boundary for every other context function that also takes
`scope`. A plain fourth positional argument matches every other
multi-field context function in this module and needs no new shape.

**Build the credentials panel on `<.modal>` and pass an `on_cancel` that
no-ops.** Rejected — `modal/1` wires the backdrop and Escape through the
same `data-cancel`/`JS.exec` chain its own close button uses; there is no
attribute that disables only two of the three routes while keeping
`focus_wrap`/`push_focus`/`pop_focus`. A no-op `on_cancel` would still let
Escape and a backdrop click *run* — they would just do nothing visible,
which is a worse failure mode than not wiring them at all, since a test or
a future reader would see `phx-click-away` present and assume it works.

**Skip the `DenyList.suffixes/0` fix and instead special-case
`create/4`'s own `:not_configured` handling around `denied?/1`'s fail-closed
default.** Rejected — this is the same shape of duplicated-condition risk
ADR-0017 already reasoned about for `visible?/1`; checking `suffixes/0`
directly, the same way `fetch/2` does, is one fewer thing to keep in sync
across two call sites.

## References

- M2M-S5 (issue #38) — the deciding issue, including the `M2M-A09` removal
  back-reference (EN-10/#33), the `M2M-A17`/Decision 4 amendment, and the
  M2M-S2 Decision 7 module-placement resolution
- `docs/adr/0016-m2m-client-adapter.md` — the structural token-validity
  guard `create/4` relies on rather than duplicating
- `docs/adr/0017-m2m-naming-deny-list-and-resolution-gate.md` — `denied?/1`'s
  fail-closed default and why it was exposed standalone for this ticket
- `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md` —
  the `focusStack` hazard this ticket's mutual-exclusion guard avoids
- `docs/adr/0014-secret-creation-key-consolidation-and-modal-exclusion.md` —
  the re-list-on-create and mutual-exclusion patterns this ticket reuses
- `lib/nucleus/audit/event.ex` — the `m2m_client_created` catalogue entry
  this ticket's audit call matches, over the wiki's own (stale) table
- Wiki [M2M-Clients](https://github.com/dave-bell/nucleus/wiki/M2M-Clients)
  `M2M-A08`, `M2M-A17`, `M2M-A18`
