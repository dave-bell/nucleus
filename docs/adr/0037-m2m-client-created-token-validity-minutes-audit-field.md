# ADR-0037: `m2m_client_created` Gains `token_validity_minutes` — Widen the Catalogue, Not the Wiki Page

## Status

Accepted — 2026-09-28

Decided on [AUD-D1](https://github.com/dave-bell/nucleus/issues/100). Supersedes
`0020-m2m-client-creation-and-credentials-panel.md`'s "Negative" note recording
this exact drift as known debt — that ADR followed the master catalogue as it
stood at the time (`lib/nucleus/audit/event.ex`'s narrower allowlist), which
this ADR now records as the stale side of the pair, not the authoritative one.

## Context

`docs/requirements/M2M-Clients.md`'s audit-events table listed
`m2m_client_created`'s fields as `client_name`, `ticket_id`,
`token_validity_minutes`. `docs/requirements/Audit-and-Compliance.md` — the
page that states its own table is the complete audit event catalogue — listed
only `user, tenant, client_name, ticket_id` for the same event, and
`lib/nucleus/audit/event.ex`, built from that master table, matched the
narrower list. ADR-0020 recorded this exact mismatch as known debt at M2M-S5
implementation time, deliberately following the master catalogue rather than
resolving it.

AUD-D1 was opened to resolve the drift, the same shape `DEX-D2` (#79) resolved
for `nomad_var_viewed` — one requirements page describing a field the
authoritative catalogue and the implementation do not have. The ticket's own
initial recommendation was to drop the field from `M2M-Clients.md`, on the
grounds that a feature page should not describe a superset of the master
catalogue, and that the value was already visible on the client detail view.
That recommendation was rejected on the issue thread before implementation
began.

## Decision

### Widen the catalogue to match the feature page — do not trim the feature page

The client detail view's display of the current token validity
(`M2M-A03`/`M2M-A16`) is a live read from Cognito, not the audit trail —
the recommendation's citation of `M2M-A15` was wrong; that action is "No
update or delete of clients," unrelated to either display path. A live read
answers "what is the validity now"; it cannot answer "what was it set to at
creation" once a client is later changed or deleted directly in Cognito,
bypassing Nucleus entirely. The audit trail recorded at creation time is the
only durable record of that fact once Cognito's own state has moved on.

`token_validity_minutes` is also a security parameter the operator chooses
(5–60 minutes, default 15, per `docs/adr/0016-m2m-client-adapter.md`'s
structural range guard) — closer in kind to `env_names_updated`'s
`added`/`removed` pair (`AUD-A04`: record what changed, not just that a change
happened) than to incidental metadata. `client_name` and `ticket_id` already
identify *which* resource was created and *why*; `token_validity_minutes`
records a security-relevant *what*, the same category `AUD-A04` asks for.

### Record it in minutes as entered, not Cognito's seconds

`Nucleus.M2M.create/4`'s own `token_validity_minutes` parameter — the value
threaded from the M2M-S4 form through to `Clients.create_client/2` — is
recorded directly in the `Audit.emit(:m2m_client_created, ...)` call's
`details`, unconverted. `Clients.create_client/2`'s own adapters translate to
Cognito's `AccessTokenValidity`/`token_validity_seconds` internally
(`docs/adr/0016-m2m-client-adapter.md`); the audit field's name says minutes,
so the audit call records minutes, not the adapter's internal unit.

### `event.ex`'s allowlist widens to match, `details_required` included

`lib/nucleus/audit/event.ex`'s `m2m_client_created` spec gains
`:token_validity_minutes` in both `details_allowed` and `details_required` —
required, not merely permitted, so a future caller cannot silently omit a
field the catalogue now commits to always recording. Every existing direct
emitter (`test/nucleus/audit_case_test.exs`'s self-test of `AuditCase`) and
assertion (`test/nucleus/m2m_test.exs`'s `AUD-A01`-tagged test) is updated in
the same change, plus a new `test/nucleus/audit_test.exs` case proving the
now-required field is enforced — the same "a required detail key raises when
missing" shape already covering `nomad_var_updated`'s `:path`.

### The wiki-side fix is a commit in the wiki repo, not just a submodule bump

`docs/requirements` is a pinned submodule of `dave-bell/nucleus.wiki`.
`Audit-and-Compliance.md`'s row is edited and committed directly in that
repository (`master` branch, pushed to `origin`), and only then is this
repository's submodule pointer bumped to the new commit — mirroring the
pattern `92cfa48`/`e55663c` already established for prior wiki-side
requirement corrections. `M2M-Clients.md` needed no change; it was already
correct.

## Consequences

### Positive

- The master catalogue and every feature page it summarizes now agree for
  this event — no reader hits the drift ADR-0020 flagged and left open.
- `token_validity_minutes` is durably recorded independent of Cognito's own
  state, closing the gap the recommendation's `M2M-A15` mis-citation
  obscured: the detail view's live read and the audit trail's point-in-time
  record now serve two different, both-necessary purposes rather than one
  being assumed redundant with the other.
- The field is `details_required`, not merely `details_allowed` — a future
  refactor of `M2M.create/4`'s emit call that drops the argument fails loudly
  (`ArgumentError`) rather than silently narrowing what the catalogue
  promises.

### Negative

- `AUD-S2` (#103), already closed, tagged the pre-widening assertion at
  `test/nucleus/m2m_test.exs:513` with `AUD-A01`. That line moves under this
  ADR's change; the tag travels with it, but a reader diffing AUD-S2's own
  merge commit against `main` today will see a line that has since changed
  again, for an unrelated reason.
- Every other `m2m_client_created` emitter or direct-emit test call site now
  needs `token_validity_minutes` present, permanently — there is no
  optional/legacy path for a caller that predates this field.

## Alternatives considered

**Drop `token_validity_minutes` from `M2M-Clients.md` instead, trimming the
feature page to match the narrower master catalogue.** This was the ticket's
own initial recommendation, rejected on the issue thread. Rejected because its
central premise — that the detail view already surfaces this value, making a
second record redundant — conflated a live Cognito read with a durable
audit record of the value *at creation time*, and cited the wrong action
(`M2M-A15`, "no update or delete," rather than `M2M-A03`/`M2M-A16`, the actual
display actions) in doing so.

**Leave `event.ex` as `details_allowed` only, not `details_required`.**
Considered and rejected — an optional field a caller can silently omit is a
weaker guarantee than the catalogue widening is meant to provide; `AUD-A04`
asks that the audit trail record what changed, and an audit event that
sometimes carries the field and sometimes does not would reintroduce a
smaller version of the same drift this ADR resolves.

## References

- AUD-D1 (issue #100) — the deciding issue, including the full rejected
  recommendation and the accepted plan
- `docs/adr/0020-m2m-client-creation-and-credentials-panel.md` — the ADR
  whose "Negative" note recorded this exact drift as known debt, superseded
  by this decision
- `docs/adr/0016-m2m-client-adapter.md` — the structural 5–60 minute range
  guard and the Cognito unit translation this ADR's audit field deliberately
  does not duplicate
- DEX-D2 (issue #79) — the precedent for this shape of catalogue-drift
  decision, resolved in the opposite direction (dropped the field, not
  widened the catalogue)
- `lib/nucleus/audit/event.ex` — the widened `m2m_client_created` catalogue
  entry
- `lib/nucleus/m2m.ex` — the `Audit.emit(:m2m_client_created, ...)` call
  now carrying `token_validity_minutes`
- `docs/requirements/Audit-and-Compliance.md`, `docs/requirements/M2M-Clients.md`
  — the master catalogue row widened to match the feature page, which needed
  no change
</content>
