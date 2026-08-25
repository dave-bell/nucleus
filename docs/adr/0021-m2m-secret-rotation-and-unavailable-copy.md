# ADR-0021: M2M Secret Rotation, Confirmation, and Honest `:unavailable` Copy

## Status

Accepted — 2026-08-25

Decided on [M2M-S6](https://github.com/dave-bell/nucleus/issues/39). Builds on
`0016-m2m-client-adapter.md` (`Clients.rotate_secret/1`'s Cognito two-secret
sequence, already implemented by EN-10 and reused verbatim here),
`0019-m2m-client-detail-mount-audit-guard-and-token-validity.md` (`Show`'s
existing `fetch/2`/`view/2` split and its `assign_result/2` error collapse,
extended rather than duplicated), and `0020-m2m-client-creation-and-credentials-panel.md`
(the `CredentialsPanel` this ticket reuses, and the `focusStack`
mutual-exclusion hazard it names as the reason two conditionally-rendered
modals cannot both be open at once).

## Context

M2M-S6 implements `M2M-A11` (rotate a client's secret, old secret valid
until the next rotation) and `M2M-A12` (confirm before rotating, three
facts, cancel with no change). Everything the actual Cognito/local
two-secret sequence needs — list, delete the older secret if two exist, add
a new one — already existed (`Clients.rotate_secret/1`, EN-10/#33); this
ticket's own work is the gate in front of it, the confirmation UI, and what
happens when the sequence fails partway through.

One thing the ticket's plan left as a design choice rather than a
specification: the `Failure` section says `:unavailable` should let "the
operator retry" and warns that the copy must not imply nothing happened,
without saying *how* retry is offered or *where* the failure renders.

## Decision

### `Nucleus.M2M.rotate/2` mirrors `create/4`'s shape exactly — no drift this time

```elixir
def rotate(client_id, %Scope{} = scope) do
  with {:ok, %ClientDetail{client_name: client_name}} <- fetch(client_id, scope),
       {:ok, %ClientCredentials{} = credentials} <- Clients.rotate_secret(client_id) do
    :ok = Audit.emit(:m2m_secret_rotated, user: ..., tenant: ..., details: %{client_name: client_name})
    {:ok, credentials}
  end
end
```

Resolves through `fetch/2`, never a bare `ClientId.validate/1` —
`fetch/2` is the only function enforcing both the format check and the
deny-list/tenant gate (`M2M-A14`), matching `create/4`'s own reasoning for
using `DenyList.suffixes/0` directly rather than `denied?/1` alone. Unlike
M2M-S5's `create/4` (ADR-0020), this ticket's own plan text and the shipped
`@spec` agree exactly — `rotate(client_id, scope)`, two arguments, nothing
grew.

### `CredentialsPanel` gains a `title` attribute; it stays one component

`credentials_panel/1`'s hardcoded `"Client created"` heading became
`attr :title, :string, default: "Client created"`, with `Show` passing
`title="Secret rotated"`. Every other piece of copy — the field labels, the
one-time warning, the dismiss button — reads identically whether the secret
was just created or just rotated, so only the heading needed a caller-supplied
value. Forking the component for one word would have created a second place
to keep the dismissal-only, no-backdrop, no-Escape behaviour correct — the
exact risk ADR-0020 already flagged as a negative consequence of that
design. Parameterizing, per the ticket's own instruction, keeps it one
component with one behaviour to audit.

### Rotation failure: four kinds collapse to `Show`'s existing page states; `:unavailable` does not

`:not_found`, `:invalid`, `:not_configured`, and `:auth_expired` reuse
`assign_result/2` unchanged — the same function `mount/3` already calls —
because each of those means the page's own premise (a resolvable, in-tenant
client) no longer holds. `#m2m-client-detail` stops rendering, identically
to a failed initial load.

`:unavailable` is deliberately different, and does **not** collapse to
`NucleusWeb.M2MClientsLive.States.unavailable/1`. Cognito's rotation
sequence is list, delete the older secret, add a new one; a failure can
land after the delete and before the add, so the client may now hold only
one secret. Collapsing this to the shared, page-replacing `:unavailable`
state would do two things at once, both wrong: hide the client detail
behind a generic "can't reach the directory, retry" screen, and imply — via
that screen's own copy, written for a *list* that failed to load, not a
*mutation* that may have partially applied — that nothing happened. Instead,
`:rotate_error` is a page-local assign; `#m2m-client-detail` keeps
rendering, and a `#rotate-secret-error` banner reads:

> Rotating the secret failed. Reload this page and check before retrying —
> the previous secret may or may not still be valid.

### "The operator can retry" means the existing rotate button, not a second control

The ticket's plan named a retry affordance for `:unavailable` without
specifying its shape. This ticket does not add one: `#rotate-secret-button`
remains enabled after a failed rotation, and clicking it re-opens
`#rotate-secret-confirm` — the same confirm-then-rotate flow, not a
dedicated "Retry" button that skips confirmation. A transient Cognito
failure is not a reason to skip `M2M-A12`'s three-fact confirmation on the
very next attempt; nothing about *why* the previous attempt failed changes
what the operator needs to be told before trying again.

### Mutual exclusion between the confirmation modal and the credentials panel

`"confirm_rotate"` sets `:confirming_rotate, true`; every terminating branch
of `"rotate"` (success or any error kind) sets `:confirming_rotate, false`
in the same assign that either sets `:credentials` or leaves it untouched.
The two are never both `true`/non-`nil` at once — the same `focusStack`
double-pop hazard ADR-0012 first predicted and ADR-0020 fixed structurally
for `Index`'s creation modal and credentials panel, applied here to `Show`'s
confirmation modal and its own (rotation) use of the same panel.

## Consequences

### Positive

- `Clients.rotate_secret/1`'s two-secret sequence — the part of this
  feature actually dangerous to get wrong — needed zero changes; this
  ticket only had to gate entry to it and describe its failure honestly.
- `CredentialsPanel` now serves both its callers with one implementation,
  proving out ADR-0020's bet that parameterizing beats forking for a
  component that displays secret material.
- The `:unavailable` copy is pinned by a test asserting the string "Reload"
  is present, so a future edit that drifts back toward "try again" (implying
  safety) fails the build rather than only a review.

### Negative

- `#rotate-secret-error` is a new, one-off error-display pattern
  (`div[role=alert].alert-error`) rather than a reuse of
  `NucleusWeb.M2MClientsLive.States` — deliberate, per the Decision above,
  but it means this feature now has two shapes of failure banner (the
  shared `States` components, and this local one) rather than one. Left as
  is: the two represent genuinely different situations (page failed to
  load vs. an action may have partially applied), and forcing them into one
  shape would blur that distinction back out.
- The ticket's own acceptance criterion — `mix nucleus.trace --feature M2M`
  showing "fifteen of sixteen covered, with `M2M-A10` the only gap" — undercounts
  the catalogue by one and predates a second, unrelated gap: the wiki lists
  seventeen `M2M-A*` actions (`M2M-A09` was removed by EN-10, but `M2M-A17`
  exists and was never claimed by any ticket's tests, M2M-S4 included). After
  this ticket, `mix nucleus.trace --feature M2M` reports 15 covered / 2
  uncovered — `M2M-A10` (M2M-S7, as the ticket says) and `M2M-A17`
  (pre-existing, out of this ticket's scope, not introduced by it).

## Alternatives considered

**Collapse `:unavailable` to `States.unavailable/1` like every other
kind.** Rejected — see Decision above. That component's copy ("Can't reach
the M2M client directory right now") is honest for a failed *read* and
actively misleading for a failed *write* that might have deleted a secret
before failing to add its replacement.

**A dedicated "Retry" button on the `:rotate_error` banner, wired directly
to `"rotate"`, bypassing `"confirm_rotate"`.** Rejected — it would let a
second rotation attempt skip `M2M-A12`'s confirmation entirely, and the
ticket gives no reason to believe a transient failure makes the three facts
in that confirmation any less necessary to restate.

**Fork `CredentialsPanel` into a second component for rotation.** Rejected
per the ticket's own instruction and ADR-0020's own stated reasoning: two
copies of a component that displays secret material is two places to get
the dismissal-only semantics wrong.

## References

- M2M-S6 (issue #39) — the deciding issue
- `docs/adr/0016-m2m-client-adapter.md` — `Clients.rotate_secret/1`'s
  two-secret Cognito sequence, unchanged by this ticket
- `docs/adr/0019-m2m-client-detail-mount-audit-guard-and-token-validity.md` —
  `Show`'s `assign_result/2` collapse, extended for rotation failures
- `docs/adr/0020-m2m-client-creation-and-credentials-panel.md` — the
  `CredentialsPanel` reused here, and the `focusStack` mutual-exclusion
  hazard this ticket also guards against
- `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md` —
  the origin of the `focusStack` double-pop hazard
- `lib/nucleus/audit/event.ex` — the `m2m_secret_rotated` catalogue entry
  this ticket's audit call matches (`client_name` only, never the secret)
- Wiki [M2M-Clients](https://github.com/dave-bell/nucleus/wiki/M2M-Clients)
  `M2M-A11`, `M2M-A12`
