# ADR-0036: Structured Production Logging

## Status

Accepted — 2026-09-25

Decided on [AUD-D2](https://github.com/dave-bell/nucleus/issues/101). Amends
`0004-audit-emission.md`'s "Format is decided strictly after recording"
section — audit's `:json`/`:text` split is unchanged, but the mechanism that
selects it is not: there is no longer a runtime variable in play, for either
stream.

## Context

`docs/requirements/Platform-Operations.md` documented `LOG_FORMAT`, a
variable that does not exist in the codebase. What actually existed,
`AUDIT_FORMAT` (`config/runtime.exs`), controlled only `Nucleus.Audit` —
ordinary `Logger` calls throughout the adapters (`backend.ex`, `scope.ex`,
`nomad/transport.ex`, etc.) were never touched by either variable and
emitted whatever `Logger`'s default formatter produces.

The narrow fix — split the wiki's one misleading row into two accurate
facts, no code change — was rejected as too small. The business want,
surfaced while working this ticket, is broader: production application logs
must be structured JSON too, not just audit records. That is a real scope
change, not a docs correction, so it gets its own ADR rather than being
folded into 0004's history.

## Decision

### Both streams become structured JSON in production, selected by build environment

`Logger`'s default handler is configured with `LoggerJSON.Formatters.Basic`
in `config/prod.exs` only, carrying `:request_id` metadata (the correlation
id `Plug.RequestId` sets, per `OPS-A09`). Dev and test are untouched — they
keep the existing plain-text `:default_formatter`.

This is compile-time config (`config/prod.exs`, not `config/runtime.exs`),
which forces the tuple form `logger_json`'s own docs distinguish from the
`.new/1` builder: `formatter: {LoggerJSON.Formatters.Basic, metadata: [...]}`.
`.new/1` returns a formatter that is not shaped for the config-file tuple
form and is documented for `runtime.exs`/application-code call sites, not
`config.exs`-time files.

**No runtime toggle exists for either stream's format.** `MIX_ENV` decides
it once, at build/release time. This was the explicitly rejected alternative
below, not an oversight.

### `AUDIT_FORMAT` and `Nucleus.Audit.Format.cast/1` are removed

Audit's format collapses to the per-environment compile-time defaults that
already existed in `config/config.exs` (`:json`) and `config/dev.exs`
(`:text` override) — `0004`'s decision that format is decided strictly
after recording, from an already-built `%Event{}`, is untouched by this
ADR. What changes is only that `config/runtime.exs` no longer reads an
environment variable to override that default; the `if audit_format = ...`
block and the `cast/1` function it called are both deleted outright, not
deprecated.

### `AUDIT_DEVICE` is unaffected

It selects *where* audit output goes (`:stderr`/`:stdout`/a file path), not
its format, and stays a legitimate deployment knob — `0004`'s reasoning for
giving audit an independently routable device (AUD-A06) does not depend on
the format being runtime-configurable.

## Consequences

### Positive

- Production application logs are machine-parseable without an operator
  having to opt in — closing the gap `Platform-Operations.md` implied
  existed (structured logs) but the code never delivered.
- `Logger` and `Nucleus.Audit` stay on independent pipelines, exactly as
  `0004` decided (AUD-A06) — this ADR changes *how* each pipeline's format
  is fixed, not whether they're one pipeline or two.
- One less runtime variable to misconfigure or leave undocumented:
  `AUDIT_FORMAT`'s only justification was letting an operator flip a
  boot-time raise to a different valid value neither the business nor this
  ticket's decision wanted kept.

### Negative

- Deployments that were setting `AUDIT_FORMAT=text` in a "production"
  environment to get human-readable audit output (there is no evidence any
  are, but the variable was public in the wiki) lose that ability outright.
  This is intentional: `0004` already named `:json` as "the only format
  supported in any deployed environment," so `AUDIT_FORMAT=text` in prod was
  always a misuse the boot-time raise happened not to catch, not a
  supported deployment shape.
- `logger_json` is a new dependency with no prior use in this codebase;
  `mix precommit`'s `deps.unlock --unused` step only keeps it if
  `config/prod.exs` actually references `LoggerJSON.Formatters.Basic` —
  there is now a compile-time coupling between that config line and the
  dependency staying in `mix.lock` that did not exist before.

## Alternatives considered

**Docs-only fix — split `LOG_FORMAT` into two accurate facts, no code
change.** Rejected. It would have left "should production application logs
be structured" undecided, and the business want, once surfaced, resolved
that question with a yes.

**A runtime `LOG_FORMAT` controlling both streams.** Rejected twice over: it
would reopen `0004`'s deliberate choice to keep audit and application logs
on independent pipelines (one variable implies one pipeline, or at least one
policy, governing both), and runtime configurability of output format is
explicitly not wanted — a typo-driven format flip is exactly the class of
mistake `0004`'s boot-time raise on `AUDIT_FORMAT` existed to catch, and the
simpler fix is to remove the variable rather than keep validating it.

## References

- AUD-D2 (issue #101) — the deciding issue, including the full decision
  thread and rejected alternatives in detail
- `docs/adr/0004-audit-emission.md` — the ADR this amends; "Format is
  decided strictly after recording" section in particular
- `docs/requirements/Platform-Operations.md` — the wiki page whose
  `LOG_FORMAT` row prompted this ticket; corrected in the same PR
- `docs/runbook/audit-retention-test.md` — operator checklist, updated to
  drop its `AUDIT_FORMAT` item
- [`logger_json`](https://hexdocs.pm/logger_json) — `LoggerJSON.Formatters.Basic`,
  the formatter wired into `config/prod.exs`
