# ADR-0002: Backend Adapter Boundaries

## Status

Accepted — 2026-08-07

Decided on [EN-2](https://github.com/dave-bell/nucleus/issues/2). Builds on
`0001-no-local-datastore.md`.

The wiki's `ADR-0001` (plugin architecture) and `ADR-0007` (local backend
implementations), under `docs/requirements/`, describe an earlier Python
prototype and are **reference only**. Where this ADR reaches the same conclusion,
it is because that conclusion was re-tested against this stack — not by
inheritance. The sections below say explicitly which decisions carry over and
which change shape because this is Elixir/LiveView rather than FastAPI/React.

## Context

Nucleus holds no data of its own; every value it displays is read live from an
external system. The Secrets feature alone reads from two:

- the tenant's **AWS SSM Parameter Store**, for the secrets themselves, reached
  by assuming a scoped role in the tenant's AWS account
- the tenant's **backing API**, for the authoritative environment list that
  environment names are validated against before any parameter path is
  constructed (`SEC-A15`–`SEC-A17`, fail closed)

Two problems follow from calling those systems directly.

**A fresh clone would not run.** Parameter Store access requires a cross-account
IAM role provisioned by Terraform. Without a local implementation, every
developer and every CI job needs that role — including a developer touching only
environment listing, who needs no AWS access at all. The prototype's CI passed
eight dummy environment variables purely to satisfy configuration validation,
which is an honest description of the problem: the credentials were required by
the code's shape, not by the work.

**Backend-specific failures would leak into LiveViews.** The prototype caught an
SSM-specific `CredentialsExpiredError` in route code and reused `KeyError` for
two unrelated meanings. Once a LiveView knows a backend's exception types, the
backend is no longer replaceable, and the "swappable interfaces" constraint in
`technical-domain.md` is documentation rather than fact.

This ADR covers only the shared scaffolding. The two concrete boundaries are
delivered by EN-3 (`:tenant_api`) and EN-4 (`:secrets`).

## Decision

### Behaviours, not protocols

Each boundary is an Elixir **behaviour** with `@callback` declarations, and each
implementation is a module declaring `@behaviour`. This is the same decision as
the prototype's `Protocol`/ABC in intent, in the idiom of a different language.
It is also stronger: the prototype needed `mypy` plus a hand-written
`_conformance_check.py` module because `runtime_checkable` protocols verify only
that a method exists, not its arity or signature. `@behaviour` warns at compile
time on a missing or wrongly-arity'd callback, and `mix precommit` compiles with
`--warnings-as-errors`, so that warning is a build failure.

No further conformance machinery is added. What `@behaviour` gives is enough.

### Tagged tuples, not exceptions

Callbacks return `{:ok, value}` or `{:error, %Nucleus.Backend.Error{}}`. Errors
are **returned, never raised**.

A `rescue` inside a `handle_event/3` is not an acceptable control-flow
mechanism: it makes the failure path invisible to the reader, and it cannot be
made exhaustive. Returning a struct with a `kind` field means a LiveView selects
its message by pattern-matching, and adding a kind makes every incomplete `case`
a compile-time warning.

`Nucleus.Backend.Error` is deliberately a plain struct with no `exception/1` —
if it were an exception, `rescue` would remain a plausible choice.

### Six neutral error kinds

`Nucleus.Backend.Error` carries `kind`, `message`, `boundary` and `details`.
`business-tech-bridge.md` records that requirement status codes are binding as
*behaviour*, not as literal HTTP responses in a LiveView, so each kind names the
meaning rather than the number:

| `kind` | Meaning | Requirement status code |
|---|---|---|
| `:invalid` | Caller-supplied input rejected before any backend call | 400 |
| `:not_found` | Well-formed identifier, no such resource | 404 |
| `:already_exists` | Create conflicted with an existing resource | 409 |
| `:auth_expired` | Server-side credentials for the backend expired | 401 |
| `:unavailable` | Backend unreachable, timed out, or errored | 503 / 502 |
| `:not_configured` | This boundary has no usable configuration | 503 |

This differs from the prototype's five exception classes by splitting `:invalid`
out as its own kind: input rejected before any backend call is reached is not a
backend failure, and conflating the two is how `KeyError` came to mean two
things.

`:auth_expired` describes *Nucleus's* credentials for a backend — an expired
assumed role — not the end user's session. Those are separate concerns and
`SEC-A18` handles the latter.

`Error.kinds/0` returns the full list, and a unit test reads the `@type kind`
union back out of the compiled type chunk and asserts the two agree. Adding a
seventh kind therefore fails that test until it is added to both, which is the
prompt to revisit every `case` matching on one.

`message` is developer-facing and may be logged; secret material never goes in
it, and never in `details`.

### `health_check/0` on every boundary behaviour

Every behaviour defined by EN-3/EN-4 declares:

```elixir
@callback health_check() :: :ok | {:error, Nucleus.Backend.Error.t()}
```

Readiness must be answerable *through* the boundary. The prototype's `/ready`
reached into a plugin's private client attribute — a boundary violation that
went unnoticed only because there was a single implementation to test against.
Declaring the callback on the behaviour makes the same mistake a compile
warning.

The readiness endpoint that consumes it belongs to Platform Operations
(`OPS-*`), not here.

### Per-boundary `real`/`local` selection

`Nucleus.Backend.impl_for/1` resolves a boundary to a module from
`Application.get_env(:nucleus, :backends)`, at call time so that
`config/runtime.exs` and test overrides both take effect. It **raises** on an
unknown or unconfigured boundary, or on a configured module that is not loaded:
that is a deployment mistake, not a runtime condition a LiveView could sensibly
render, and the message names the boundary and both of its implementations.

- `config/config.exs` selects the real implementations.
- `config/dev.exs` and `config/test.exs` select the local implementations, so a
  fresh clone runs and `mix test` passes with no credentials.
- `config/runtime.exs` overrides per boundary via `SECRETS_BACKEND` and
  `TENANT_API_BACKEND`, each `"real"` (default) or `"local"`. An unrecognised
  value raises at boot rather than falling back.

Selection is **per boundary, not one global switch** — carried over from wiki
ADR-0007 for the same reason it was chosen there. The pain being solved is
specific to Parameter Store's cross-account role; a single switch would force an
all-or-nothing choice on a developer who wants a real tenant API and a local
secrets store.

`Nucleus.Backend` holds the `boundary -> %{real: module, local: module}` registry
and is the single source of truth for which module means which mode.
`config/runtime.exs` asks it rather than repeating the mapping, since runtime
configuration is evaluated after compilation. `config/config.exs` cannot — it is
evaluated before the module exists — so the default module names are literals
there. A unit test asserts the test-environment configuration equals the
registry's local implementations, which is what catches drift between the two.

### Authentication is never swappable

There is no `:auth` boundary and no `AUTH_BACKEND`. Authentication is the actual
security boundary; making it swappable would make an authorisation bypass a
configuration mistake. (Auth itself is deferred — see EN-6.)

### Local implementations ship, with a loud boot warning

Local implementations are included in the release, and
`Nucleus.Application.start/2` calls `Nucleus.Backend.warn_on_local_backends/0`,
which logs one warning naming every boundary currently serving in-memory data
and the variable that switched it.

The alternative — excluding them from the production build — is rejected for the
reason wiki ADR-0007 gives: it requires a package list and a build stage to stay
in sync, and a mistake there silently breaks local development rather than
failing loudly. Because auth is never swappable, a stray `*_BACKEND=local` in
production shows wrong data to users who are already authenticated and
authorised. That is a functional bug, not an auth bypass, and a warning on every
boot is the cheap, proportionate signal.

### Fault injection is required, not optional

`Nucleus.Backend.Faults.maybe_fault/1` reads two environment variables and is
called first in every local implementation callback:

| Variable | Effect |
|---|---|
| `LOCAL_LATENCY_MS` | Sleep this long before returning |
| `LOCAL_FORCE_ERROR` | Return `{:error, %Error{kind: <named kind>}}` instead of succeeding |

Canned data that always succeeds instantly never exercises a spinner or an error
branch. `SEC-S1` (fail closed on `:unavailable`) and `SEC-S7` (`:auth_expired`
surfacing as re-authentication) are not testable at all without this, so it is
part of the boundary scaffolding rather than a developer convenience.

Both variables are read on **every call**, deliberately: a developer flips a
fault without restarting. Both **raise** on an unparseable value — a typo in a
fault flag that silently returned `:ok` would turn a test asserting an error path
into one that passes for the wrong reason.

## Consequences

- **A fresh clone runs and its full test suite passes with no credentials**, no
  AWS role, and no external services. CI needs no dummy environment variables to
  satisfy configuration.
- **Every `mix test` run logs the local-backends warning once.** That is the
  intended signal, not noise to suppress.
- **LiveViews match on `Nucleus.Backend.Error.kind`**, and a LiveView that
  imports a backend-specific error type is a review failure with a named rule to
  cite.
- **Two implementations per boundary must stay in agreement.** EN-8's test
  harness owns the shared behaviour-contract suite that runs the same assertions
  against both. Contract tests cannot catch every behavioural nuance — real
  SSM's eventual consistency, for one.
- **`impl_for/1` raises today for both boundaries**, because
  `Nucleus.Secrets.Store.Local` and `Nucleus.TenantApi.Local` do not exist until
  EN-4 and EN-3. The message says so by name. Nothing calls `impl_for/1` yet.
- **Callback signatures are not yet settled for token passthrough.** How the
  signed-in user's access token reaches a boundary across a long-lived LiveView
  socket is an open question (`living-notes.md`). EN-3 and EN-4 define the first
  real callbacks and will have to answer it; this ADR constrains only the return
  shape, which is unaffected.
- **No mocking library is introduced.** Real local implementations plus contract
  tests replace `Mox`/`Hammox`. Adding one later is a new decision.

## Alternatives considered

**Direct calls to `ExAws`/`Req` from context modules, no boundary.** Rejected.
It is the state the prototype was trying to leave: no way to run without live
infrastructure, and backend exception types reaching route code.

**A single global `BACKEND_MODE`.** Rejected, same reasoning as wiki ADR-0007 —
the cost being avoided is specific to one boundary, so the switch should be too.

**Raising a `Nucleus.Backend.Error` exception instead of returning it.**
Rejected. It reads more concisely at the call site and much worse at the failure
site: `rescue` in `handle_event/3` cannot be checked for exhaustiveness, and
every LiveView would need one.

**Excluding local implementations from the release build.** Rejected — see the
boot-warning section above.

**A mocking library (`Mox`, `Hammox`) instead of local implementations.**
Rejected. Mocks exist only for tests, so they drift from anything a developer can
run, which is exactly how the prototype ended up with hand-written `Fake*`
classes *and* no local mode. One local implementation per boundary serves both.

**Deriving "is this local?" from the module name suffix.** Rejected as
stringly-typed: an explicit registry in `Nucleus.Backend` costs two lines per
boundary and cannot be defeated by a rename.

## References

- EN-2 — the deciding issue, including the full implementation plan
- `docs/adr/0001-no-local-datastore.md` — the stateless constraint local
  implementations must not breach (in-memory per process, never persisted)
- Wiki [ADR-0001](https://github.com/dave-bell/nucleus/wiki/ADR-0001-Monolith-with-Plugin-Architecture),
  [ADR-0007](https://github.com/dave-bell/nucleus/wiki/ADR-0007-Local-Backend-Implementations)
  — reference only; prior art, not authority
- `.opencode/context/project-intelligence/technical-domain.md` — "Pluggable
  backends" constraint
- `.opencode/context/project-intelligence/business-tech-bridge.md` — status codes
  binding as behaviour, not literal HTTP responses
- EN-3, EN-4 — the concrete boundaries; EN-6 — auth; EN-8 — contract test harness
