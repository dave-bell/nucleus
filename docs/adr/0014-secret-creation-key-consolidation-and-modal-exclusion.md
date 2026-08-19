# ADR-0014: Secret Creation — Key Validator Consolidation and Modal Mutual Exclusion

## Status

Accepted — 2026-08-19

Decided on [SEC-S6](https://github.com/dave-bell/nucleus/issues/14). Builds on
`0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md` (the
provisional weak key denylist this ticket replaces),
`0012-secret-reveal-modal-and-icon-only-copy-affordances.md` (the
conditionally-rendered modal shape and its `focusStack` risk), and
`0013-secret-edit-in-modal-and-value-form.md` (the `Value`/`EditForm`
pattern this ticket's own form follows, plus its own addendum settling the
error-shape question below).

## Context

SEC-S6 implements `SEC-A09`–`SEC-A13`: creating a secret, validating its key
and value, rejecting a duplicate, and dismissing the form cleanly. Three
things the plan (issue #14) either left open or got overtaken by what
SEC-S4/SEC-S5 actually shipped:

1. `Nucleus.Secrets.reveal/3` and `update/4` carried a private, weaker key
   denylist (`..`, `/`, `\`, null byte only), explicitly marked provisional
   pending this ticket's consolidation.
2. The issue thread settled, before implementation began, that the key
   validator would add **no casing rule** — the plan itself did not specify
   this, but the decision was made deliberately as part of this ticket
   rather than deferred further.
3. ADR-0012 already predicted that a second conditionally-rendered modal
   (this ticket's creation form, alongside SEC-S4's reveal modal) risked a
   `focusStack`/`JS.pop_focus/1` double-pop if both were ever open at once,
   without prescribing the fix.

## Decision

### `Nucleus.Secrets.Key.validate/1` is the one key validator, denylist not allowlist

One function, in `lib/nucleus/secrets/key.ex`, replacing the private copies
in `reveal/3` and `update/4` and backing the new `create/4`. Denylist
exactly as the wiki specifies — empty, over 256 characters, `/`, `\`, a
null byte, `..` — not `Nucleus.Environments.validate_name/1`'s allowlist:
keys are user-chosen and resemble environment-variable names (dots, dashes,
mixed case are all legitimate), where an allowlist strict enough to matter
would reject real keys.

### It returns `Nucleus.Backend.Error.t()`, not a bare reason atom

The plan specified `:ok | {:error, atom()}`. Settled against
`Nucleus.Secrets.Value.validate/1`'s already-landed shape instead (see
ADR-0013's addendum): two sibling validators feeding the same `create/4`
`with` chain returning different shapes on failure would be an accident of
authorship order, not a deliberate choice. The per-rule distinction
`SEC-A10` requires lives in `error.details.reason` — one of `:empty`,
`:too_long`, `:forward_slash`, `:backslash`, `:null_byte`,
`:path_traversal` — checked in a fixed order so a key violating more than
one rule reports deterministically, while `error.message` carries the
distinct human-readable copy the form shows directly.

### No casing rule, and no create-only tightening beyond the wiki's four denied sequences

Considered and rejected: "lowercase except the final, uppercase segment,"
meant to mirror the seeded fixtures' `DATABASE_URL`-style convention. The
deciding argument is asymmetric risk, not aesthetics: a validator that
wrongly rejects a legitimate key does not stop an operator, it routes them
to the AWS console directly, where no `secret_created` event exists and
nothing is audited. Wrongly permissive costs a cosmetically inconsistent
key name; wrongly strict costs audit coverage that cannot be reconstructed
afterward. Reinforcing that: the requirement is silent on casing (`SEC-A10`
enumerates its rules exhaustively and casing is not among them), Parameter
Store keys created outside Nucleus can be any casing regardless of what a
create-only rule enforces, and `Nucleus.Secrets.list/2` already sorts
case-insensitively to cope with that reality. The convention is expressed
as guidance only — a `placeholder="DATABASE_URL"` on `#new-secret-key` plus
a hint line beneath it — never enforcement. Duplicate detection stays
case-sensitive, matching Parameter Store's own semantics exactly as
planned.

### The 256-character cap applies uniformly — read, write, and create alike

`Key.validate/1` backs `reveal/3` and `update/4` as well as `create/4`,
with one rule set rather than a stricter create-time cap layered on a
looser read-time one. The accepted, documented consequence: a key longer
than 256 characters created outside Nucleus would be listable (`list/2`
runs no per-key validation) but not revealable (`reveal/3` does). Stated
directly in `Key`'s `@doc` rather than left to be discovered as a bug
report.

### The creation form is `NucleusWeb.SecretsLive.CreateForm`, following `EditForm`'s landed shape

An `embedded_schema` with `:key` and `:value`, in the web layer — not
`lib/nucleus/secrets/new_secret.ex` in the domain layer as the plan
originally specified. ADR-0013 chose the web-layer placement specifically
so this ticket would not have to rediscover it; this ticket follows that
choice rather than revisiting it. `changeset/3` takes an `existing_keys`
list (from the LiveView's already-loaded stream) for `SEC-A10`'s advisory,
form-side duplicate check — `SEC-A12`'s backend `:already_exists` rejection
via `Store.create_secret/3`'s atomic `Overwrite: false` refusal remains the
authoritative, race-safe check; `create/4` never reads before writing.

### The creation modal and the reveal modal are mutually exclusive, not merely unlikely to overlap

Both are `Phoenix.Component`-conditional (`:if={@creating}` /
`:if={@revealed}`), matching the reveal modal's own shape rather than the
"mounted and toggled" usage ADR-0012 calls acceptable for a creation form.
Opening either resets the other's assigns to its closed state in the same
step: `"new_secret"` clears `:revealed`/`:editing`/`:edit_form`, and
`"reveal"` clears `:creating`/`:create_form`. This is the concrete fix for
the `focusStack` double-pop ADR-0012 predicted — structurally preventing
both modals from existing at once, rather than patching the interaction
after two were observed stacked. A client can dispatch either `phx-click`
directly regardless of which button is visually reachable behind a
backdrop, so the guard lives in `handle_event/3`, not in what is rendered.

### A successful create re-lists rather than computing a stream insertion position

`Nucleus.Secrets.list/2` already sorts case-insensitively with a raw-key
tiebreak; recomputing that ordering to call `stream_insert/3` at a
specific index would duplicate logic that already exists and risks getting
the tiebreak wrong. `save_new_secret/3` calls the same `fetch_secrets/2`
`handle_params/3` uses, which re-streams with `reset: true` and refreshes
`:secret_count` and `:secret_keys` in the same step — which is also what
flips `#secrets-empty` to `#secrets-table` on a first secret, with no
separate code path, the same way ADR-0013 observed `SEC-A07`'s re-masking
falls out of `:revealed` going to `nil`.

## Consequences

### Positive

- One key validator exists in the application; `reveal/3` and `update/4`'s
  provisional weak copies are gone, closing the technical-debt item ADR-0011
  opened.
- `create/4`'s `with` chain needs no special case for either `Key.validate/1`
  or `Value.validate/1`'s failure — both return the same struct.
- The `focusStack` double-pop ADR-0012 predicted is structurally impossible
  rather than merely untested — verified by a test that opens the reveal
  modal, opens the creation modal, and confirms only the latter is present.
- The no-casing-rule decision is stated in `Key`'s moduledoc, not left to be
  reverse-engineered from its absence.

### Negative

- `create/4`'s re-list on success is one extra `Store.list_secrets/1` call
  compared to a precisely-targeted `stream_insert/3` — accepted because
  correctness (matching `list/2`'s exact tiebreak) was judged more valuable
  than the saved call, and the requirement places no latency bound on it.
- Mutual exclusion between the two modals means a client dispatching
  `"reveal"` while `"new_secret"`'s modal is open loses whatever was typed
  into the creation form, with no confirmation. No requirement describes
  this interaction, and it is a narrow, deliberately-a rare path (both
  triggers are not simultaneously clickable in the rendered UI), but it is
  a real, silent discard worth naming rather than discovering later.
- `Key.validate/1`'s 256-character cap now rejects an externally-created,
  over-length key on `reveal/3`/`update/4` that `list/2` would still show —
  a narrower gap than before (previously any length reached the store), but
  not a closed one.

## Alternatives considered

**A per-rule reason atom returned bare (`{:error, :too_long}`), matching the
plan literally.** Rejected — see ADR-0013's addendum; would have required
`create/4`'s `with` chain to special-case one sibling validator's failure
shape differently from the other's.

**A casing rule modelled on the seeded fixtures'
`DATABASE_URL` convention.** Rejected at length in issue #14's comment
thread — summarized above; full reasoning lives there, not duplicated here.

**Computing a `stream_insert/3` index from `:secret_keys`' sorted
position.** Rejected — re-deriving `list/2`'s tiebreak logic a second time
in the LiveView risked the two drifting apart silently; re-listing cannot
drift because it *is* `list/2`.

**Leaving the creation modal "mounted and toggled" per ADR-0012's stated
allowance for non-sensitive content.** Rejected in favor of matching the
reveal modal's conditional shape — the resulting mutual-exclusion guard is
simpler to reason about and test as "at most one modal assign is ever
truthy" than as two different mechanisms (one conditional render, one CSS
class toggle) that both need the same guard applied differently.

## References

- SEC-S6 (issue #14) — the deciding issue, including the full key-casing
  rejection and the error-shape/form-placement divergences flagged before
  implementation began
- `docs/adr/0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md`
  — the provisional weak key validator this ticket replaces
- `docs/adr/0012-secret-reveal-modal-and-icon-only-copy-affordances.md` —
  the `focusStack` double-pop risk this ticket's mutual-exclusion guard
  resolves, and the two legitimate `<.modal>` usages
- `docs/adr/0013-secret-edit-in-modal-and-value-form.md` — the
  `Value`/`EditForm` pattern this ticket's `Value` reuse and `CreateForm`
  follow, and its own addendum settling `Key.validate/1`'s return shape
- `AGENTS.md` — `embedded_schema`/`Ecto.Changeset` for form validation with
  no database; `to_form/2` and `<.form for={@form}>` conventions
