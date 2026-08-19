defmodule Nucleus.Secrets do
  @moduledoc """
  The public context module `NucleusWeb.SecretsLive` talks to.

  Store access always goes through here so the environment gate cannot be
  bypassed — nothing outside this module should call `Nucleus.Secrets.Store`
  directly for a request that originated from a caller-supplied environment
  name.

  ## One call, not a combined result (`SEC-S2` decision 1)

  `list/2` gates internally via `Nucleus.Environments.fetch/2` and discards
  the resulting `%Nucleus.TenantApi.Environment{}` — the environment response
  is never merged with the secrets response, because the two backend
  boundaries stay separate (`:tenant_api` vs `:secrets`, see
  `Nucleus.Backend.Error.boundary`). The gate is load-bearing, not merely
  defensive: `Nucleus.Secrets.Store.Local.list_secrets/1` does
  `Map.get(buckets, environment, %{})`, so a nonexistent environment returns
  `{:ok, []}` — indistinguishable from a seeded empty environment
  (`SEC-A14`). `GetParametersByPath` behaves the same way against a path with
  nothing under it. Without this gate, `/environments/nope/secrets` would
  render `SEC-A14`'s "no secrets found" plus a create button for an
  environment that does not exist.

  Callers distinguish the two boundaries' `:unavailable` errors by matching
  on `error.boundary`, not just `error.kind` — both arrive with
  `kind: :unavailable`.

  ## `reveal/3` owns the one plaintext fetch (`SEC-S4`)

  `list/2` deliberately never calls `Store.get_secret/2` — see its own doc.
  `reveal/3` is the only function in this module that does, and the only one
  that emits `:secret_viewed`. Keeping the two separate means `SEC-A01`'s
  "never included in the listing response" is not something a future change
  to `list/2` could quietly break by merging in a value.

  ## `update/4` mirrors `reveal/3`'s validation ladder, but owns no gate (`SEC-S5`)

  `update/4` re-validates the environment, the key shape, and — via
  `Nucleus.Secrets.Value.validate/1` — the value shape, in that order, before
  ever calling `Store.update_secret/3`. It deliberately does **not** enforce
  `SEC-A06`'s "editing requires the value to have been revealed first" — that
  precondition is UI session state this context module cannot see. See
  `update/4`'s own doc for where the gate actually lives.

  ## One key validator, shared by every function that touches a key (`SEC-S6`)

  `reveal/3`, `update/4`, and `create/4` all validate the key shape through
  `Nucleus.Secrets.Key.validate/1` — not a private copy each. Before this
  ticket, `reveal/3` and `update/4` shared a weaker, inline denylist (see
  `docs/adr/0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md`);
  `Key.validate/1` replaces it, applying the same rules and the same
  256-character cap to a read, a write, and a create alike (`Key`'s own
  moduledoc explains why that cap is deliberately not create-only).

  ## `create/4` validates before any store call, and relies on the store's atomic refusal (`SEC-A09`, `SEC-A12`)

  `create/4` does **not** implement `SEC-A12`'s "reject an existing key" as a
  read-then-write — that would be racy: another operator, or a process
  outside Nucleus, could create the key between a pre-check and the write.
  `Store.create_secret/3` already refuses atomically with
  `{:error, %Error{kind: :already_exists}}` (`Overwrite: false` on the
  underlying `PutParameter` call), so `create/4` calls it directly and lets
  that refusal propagate. See `create/4`'s own doc.
  """

  alias Nucleus.Audit
  alias Nucleus.Backend.Error
  alias Nucleus.Environments
  alias Nucleus.Scope
  alias Nucleus.Secrets.Key
  alias Nucleus.Secrets.Secret
  alias Nucleus.Secrets.SecretRef
  alias Nucleus.Secrets.Store
  alias Nucleus.Secrets.Value

  @doc """
  Every secret's metadata for `environment`, re-validating the environment
  through `scope` before reaching the store.

  Values are never fetched, merged, or prefetched here — `SecretRef` has no
  `value` field at all (`SEC-A01`), and this function does not call
  `Store.get_secret/2`.

  Results are sorted by key, ascending, case-insensitive with the raw key as
  a tiebreak: `Enum.sort_by(refs, &{String.downcase(&1.key), &1.key})`. Keys
  are unique within an environment, so nothing can tie on both terms — the
  tiebreak makes the order total, not merely case-folded, so `API_KEY` and
  `api_key` (which collide under `String.downcase/1` alone) still sort
  deterministically instead of inheriting the store's iteration order.
  Neither `Store.Local` (a JSON-decoded map, whose iteration order is not
  insertion order past 32 keys) nor `Store.Aws` (`GetParametersByPath`
  pagination, unordered across pages) guarantees a stable order on its own —
  sorting belongs here, not in the template, so the UI and the tests are not
  flaky.

  Emits no audit event: the audit catalogue
  (`Nucleus.Audit.Event.events/0`) has no `secret_listed` entry. Listing
  exposes no values, so there is nothing sensitive to attribute — unlike
  Data Export's `nomad_vars_listed`, this is a deliberate omission, not an
  oversight.
  """
  @spec list(environment :: String.t(), scope :: Scope.t()) ::
          {:ok, [SecretRef.t()]} | {:error, Error.t()}
  def list(environment, %Scope{token: token}) when is_binary(environment) do
    with {:ok, _environment} <- Environments.fetch(environment, token),
         {:ok, refs} <- Store.list_secrets(environment) do
      {:ok, sort(refs)}
    end
  end

  @doc """
  Reveals `key`'s plaintext value in `environment`, re-validating both
  before either reaches the store or a path is built (`SEC-A03`).

  Strict order:

  1. `Nucleus.Environments.fetch/2` — re-validate the environment, the same
     gate `list/2` uses. Never trust an environment name arriving from a
     client-originated event.
  2. The **key** shape, via `Nucleus.Secrets.Key.validate/1` — the single
     shared validator `update/4` and `create/4` also use, not a private
     copy. `key` comes from `phx-value-key`, which a client can forge — an
     attacker-supplied key such as `"../../other-env/secret"` must never
     reach `Nucleus.Secrets.Path.build/2`, which concatenates its arguments
     verbatim. `Key.validate/1`'s denylist (`..`, `/`, `\`, a null byte,
     empty, over 256 characters) is enough to stop a forged key from
     reaching another environment's Parameter Store path, which is the
     concrete risk this function guards against — see `Key`'s own moduledoc
     for why it is a denylist rather than `validate_name/1`'s allowlist.
  3. `Nucleus.Secrets.Store.get_secret/2` — the one place in this module a
     value is fetched.

  On success **only**, emits `secret_viewed` with `resource` set to the
  full parameter path (`secret.path`, built by `Nucleus.Secrets.Path.build/2`
  inside the store) — never the bare key. Emitting before the fetch would
  record views that never happened; emitting on failure would too, so a
  failed reveal is not a view and produces no audit record at all. `source_ip`
  is not part of `secret_viewed`'s catalogue entry (see
  `Nucleus.Audit.Event.spec/1`) and must not be passed. `user` comes from
  `Nucleus.Scope.audit_user/1`, not a raw `scope.user.email` read — Cognito
  access tokens carry no `email` claim for some users, and `audit_user/1`
  falls back to `username`, then `"anonymous"`, so a signed-in reveal is
  never misattributed to "anonymous" just because `email` happened to be
  `nil` or blank.

  Never logs, caches, or memoises the value on any branch — a fresh
  `Store.get_secret/2` call happens on every reveal, including a
  hide/re-reveal cycle, so a second reveal produces a second `secret_viewed`
  record.
  """
  @spec reveal(environment :: String.t(), key :: String.t(), scope :: Scope.t()) ::
          {:ok, Secret.t()} | {:error, Error.t()}
  def reveal(environment, key, %Scope{token: token} = scope)
      when is_binary(environment) and is_binary(key) do
    with {:ok, _environment} <- Environments.fetch(environment, token),
         :ok <- Key.validate(key),
         {:ok, secret} <- Store.get_secret(environment, key) do
      :ok =
        Audit.emit(:secret_viewed,
          user: Scope.audit_user(scope),
          tenant: scope.tenant,
          resource: secret.path
        )

      {:ok, secret}
    end
  end

  @doc """
  Updates `key`'s value in `environment` to `value`, re-validating the
  environment, the key shape, and the value shape — in that order — before
  any store call (`SEC-A06`).

  Strict order, mirroring `reveal/3`:

  1. `Nucleus.Environments.fetch/2` — the same gate every other function in
     this module uses. Never trust an environment name arriving from a
     client-originated event.
  2. The **key** shape, via the same `Nucleus.Secrets.Key.validate/1`
     `reveal/3` already uses — not a second copy. `key` comes from
     `phx-value-key`, forgeable the same way it is for a reveal.
  3. `Nucleus.Secrets.Value.validate/1` — the value shape (non-empty, at most
     4096 characters), checked before the store is ever reached, so an
     invalid value never becomes a `PutParameter` call.
  4. `Nucleus.Secrets.Store.update_secret/3` — fails `{:error, kind:
     :not_found}` on a missing key and **never creates one**; this function
     adds no upsert behaviour on top.

  On success **only**, emits `secret_updated` with `resource` set to the
  full parameter path from the returned `SecretRef` — never the bare key,
  and never the value: `SecretRef` has no `value` field, so there is nowhere
  for one to leak into the audit record even by accident. `user` comes from
  `Nucleus.Scope.audit_user/1`, matching `reveal/3` and ADR-0011's reasoning
  for why a raw `scope.user.email` read is not enough.

  Returns `SecretRef` (no value field), so the success path cannot
  accidentally carry the new plaintext back into a caller's render.

  ## This function does not enforce reveal-before-edit

  `SEC-A06`'s "editing requires the value to have been revealed first" is UI
  session state (`NucleusWeb.SecretsLive`'s `:revealed` assign) — this
  context module has no view of a caller's session and cannot check it.
  **The gate lives in the LiveView's `handle_event/3`, on both opening the
  edit form and on save.** A future caller of this function — a future API
  endpoint, a script — must add an equivalent check of its own; calling
  `update/4` directly is not safe against a blind overwrite on its own.

  The value must appear in no log line, on any branch, including a failure
  — `Store.update_secret/3`'s underlying `PutParameter` call carries the
  value in its request body, so any code that logged a failed request body
  would leak it. This function never logs, and neither does anything it
  calls.
  """
  @spec update(
          environment :: String.t(),
          key :: String.t(),
          value :: String.t(),
          scope :: Scope.t()
        ) :: {:ok, SecretRef.t()} | {:error, Error.t()}
  def update(environment, key, value, %Scope{token: token} = scope)
      when is_binary(environment) and is_binary(key) and is_binary(value) do
    with {:ok, _environment} <- Environments.fetch(environment, token),
         :ok <- Key.validate(key),
         :ok <- Value.validate(value),
         {:ok, ref} <- Store.update_secret(environment, key, value) do
      :ok =
        Audit.emit(:secret_updated,
          user: Scope.audit_user(scope),
          tenant: scope.tenant,
          resource: ref.path
        )

      {:ok, ref}
    end
  end

  @doc """
  Creates a new secret in `environment` with `key` and `value`,
  re-validating the environment, the key shape, and the value shape — in
  that order — before any store call (`SEC-A09`).

  Strict order, matching `reveal/3` and `update/4`:

  1. `Nucleus.Environments.fetch/2` — the same gate every other function in
     this module uses. Never trust an environment name arriving from a
     client-originated event.
  2. `Nucleus.Secrets.Key.validate/1` — the same validator `reveal/3` and
     `update/4` use, not a create-specific copy. `key` comes from a
     client-submitted form and is validated here regardless of whatever the
     form layer (`NucleusWeb.SecretsLive.CreateForm`) already checked —
     `SEC-A10`'s form-side check is advisory, this is authoritative.
  3. `Nucleus.Secrets.Value.validate/1` — the value shape (non-empty, at
     most 4096 characters), checked before the store is ever reached.
  4. `Nucleus.Secrets.Store.create_secret/3` — fails
     `{:error, %Error{kind: :already_exists}}` (`SEC-A12`) when `key`
     already exists in `environment`, via the store's own atomic
     `Overwrite: false` refusal. **Not** a read-then-write: this function
     never calls `Store.get_secret/2` or `list_secrets/1` first, so a
     concurrent create racing this one is still rejected correctly by
     whichever `PutParameter` call the store's implementation processes
     second — see the moduledoc's "`create/4` validates before any store
     call" section.

  On success **only**, emits `secret_created` with `resource` set to the
  full parameter path from the returned `SecretRef` — never the bare key,
  and never the value: `SecretRef` has no `value` field. `user` comes from
  `Nucleus.Scope.audit_user/1`, matching `reveal/3` and `update/4`.

  A rejected create — an invalid key, an invalid value, or an
  `:already_exists` conflict — reaches no store call that could mutate
  anything, so the existing value behind a duplicate key is guaranteed
  untouched; `SEC-A12`'s rejection is a pure read from the store's
  perspective.

  Returns `SecretRef` (no value field), so the success path cannot
  accidentally carry the new plaintext back into a caller's render. The
  new secret is **not** revealed by creating it — no `secret_viewed` event
  is emitted here, and no plaintext round-trips back through this
  function's return value.

  The value must appear in no log line, on any branch, including a failure
  — the same guarantee `update/4` makes, for the same reason.
  """
  @spec create(
          environment :: String.t(),
          key :: String.t(),
          value :: String.t(),
          scope :: Scope.t()
        ) :: {:ok, SecretRef.t()} | {:error, Error.t()}
  def create(environment, key, value, %Scope{token: token} = scope)
      when is_binary(environment) and is_binary(key) and is_binary(value) do
    with {:ok, _environment} <- Environments.fetch(environment, token),
         :ok <- Key.validate(key),
         :ok <- Value.validate(value),
         {:ok, ref} <- Store.create_secret(environment, key, value) do
      :ok =
        Audit.emit(:secret_created,
          user: Scope.audit_user(scope),
          tenant: scope.tenant,
          resource: ref.path
        )

      {:ok, ref}
    end
  end

  defp sort(refs) do
    Enum.sort_by(refs, &{String.downcase(&1.key), &1.key})
  end
end
