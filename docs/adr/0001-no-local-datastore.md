# ADR-0001: No Local Datastore

## Status

Accepted — 2026-08-07

Decided on [EN-1](https://github.com/dave-bell/nucleus/issues/1). This is the first
ADR adopted by this codebase. The `ADR-0001`–`ADR-0007` documents under
`docs/requirements/` belong to an earlier Python prototype and are **reference
only — not adopted here**.

## Context

`mix phx.new` scaffolded this project with Ecto and PostgreSQL: a `Nucleus.Repo`
in the supervision tree, `ecto_sql` + `postgrex` dependencies, a `priv/repo/`
directory, per-environment database configuration, and SQL sandbox plumbing in the
test support files.

Nothing used any of it. No schema, no migration, no query.

This directly contradicts the **stateless** constraint adopted from the wiki's Core
model:

> Nucleus holds no database of its own. Every value it displays is read live from
> Nomad, Parameter Store, or Cognito.

Leaving a live `Ecto.Repo` in the supervision tree is not a neutral no-op. It is an
invitation: the next contributor who hits a slow Parameter Store call will "just
cache the secret", or the one implementing audit will "just store the audit log
locally", and the constraint erodes without anyone deciding to abandon it. A repo
that starts successfully looks like a sanctioned place to put state.

It also imposed real cost for zero benefit — local development and CI both needed a
running PostgreSQL instance to execute a test suite that never touched a database.

The decision was forced by sequencing: SEC-S6 builds a secret-creation form with key
and value validation, and its implementation approach depends on whether
`Ecto.Changeset` is available.

## Decision

**Drop the database. Keep the changeset library.**

Removed:

- `ecto_sql` and `postgrex` dependencies (and `db_connection`, transitively)
- `Nucleus.Repo` from the supervision tree, and `lib/nucleus/repo.ex`
- `priv/repo/` entirely
- `test/support/data_case.ex`, the `ConnCase` sandbox delegation, and the
  `Ecto.Adapters.SQL.Sandbox.mode/2` call in `test/test_helper.exs`
- All `Nucleus.Repo` configuration from `config/config.exs`, `dev.exs`, `test.exs`
  and `runtime.exs` — including the `DATABASE_URL` / `POOL_SIZE` / `ECTO_IPV6` block
- The `Phoenix.Ecto.CheckRepoStatus` plug from `lib/nucleus_web/endpoint.ex`
- The five dead `nucleus.repo.query.*` telemetry metrics from
  `lib/nucleus_web/telemetry.ex`
- The `ecto.setup` / `ecto.reset` aliases, and the `ecto.create` / `ecto.migrate`
  steps from the `test` and `setup` aliases

Retained, deliberately:

- **`ecto`** — now an explicit dependency, having previously been pulled in
  transitively by `ecto_sql`
- **`phoenix_ecto`** — provides the `Phoenix.HTML.FormData` implementation for
  `Ecto.Changeset`

`Ecto.Changeset` and `embedded_schema` are the idiomatic way to build a validated
Phoenix form, and `AGENTS.md` mandates driving forms through `to_form/2`. None of
that requires a database, a repo, an adapter, or a migration. Dropping `ecto`
altogether would force hand-rolled `to_form(params, errors: ...)` plumbing in SEC-S6
for no gain.

## Consequences

- **The stateless constraint is now structurally enforced, not merely documented.**
  Adding a cache or a local table means adding a dependency, a repo and
  configuration — a visible, reviewable act rather than an incidental one.
- **Audit records must go to an external log pipeline**, not a local table. There is
  no longer anywhere to put them. See EN-5, which owns that decision; this ADR only
  closes off the local option.
- **No PostgreSQL for development or CI.** `mix setup` no longer touches a database;
  `mix test` runs with no external services.
- **`ConnCase` needs no database setup** and cases may run `async: true` freely. EN-8
  (test harness) has no sandbox plumbing to wrap.
- **SEC-S6 proceeds with `embedded_schema` + `Ecto.Changeset`**, with `to_form/2`
  available via `phoenix_ecto`.
- **`ecto` is for changesets only.** A future contributor adding `ecto_sql` to get a
  repo back is reopening this ADR, and should say so.
- **`Phoenix.LiveDashboard`'s Ecto stats page is inert**, and emits a compile-time
  warning from within the dependency about `Postgrex.Interval` being unavailable.
  Harmless, and not worth suppressing.

## Alternatives considered

**Keep Postgres, narrow the stateless constraint.** Rejected. The constraint comes
from the binding requirements, not from a preference, and nothing in the current
scope needs persistence.

**Drop `ecto` entirely alongside `ecto_sql`.** Rejected. It buys nothing — `ecto`
pulls in no database machinery on its own — and costs hand-written form-error
plumbing in every validating form, starting with SEC-S6.

**Leave the repo in place but unstarted.** Rejected as the worst of both: the
dependency, configuration and setup burden remain, while the thing itself is
non-functional and misleading.

## References

- EN-1 — the deciding issue, including the full removal plan
- Wiki [Home](https://github.com/dave-bell/nucleus/wiki/Home) — Core model,
  "Stateless" row
- `AGENTS.md` — form handling via `to_form/2`; `mix precommit` as the required gate
- EN-5 — where audit records actually go
