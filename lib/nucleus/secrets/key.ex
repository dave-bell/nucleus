defmodule Nucleus.Secrets.Key do
  @moduledoc """
  Shape validation for a secret's key — the authoritative rules `SEC-A10`
  describes, shared by every path that touches a key: `create/4` (`SEC-A09`,
  this ticket, `SEC-S6`), and `reveal/3`/`update/4`, which previously carried
  their own weaker, second copy of this denylist (see
  `docs/adr/0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md`).
  There is exactly one key validator in the application after this module
  lands — `Nucleus.Secrets` no longer defines its own `validate_key/1`.

  ## Denylist, not allowlist — and that is deliberate

  Contrast this with `Nucleus.Environments.validate_name/1`, which layers a
  positive charset allowlist on top of the same three denied sequences.
  That contrast looks like an inconsistency and is not: an environment name
  is operator-chosen from a small, controlled set (config, a provisioning
  script) and gains nothing from allowing dots, mixed case, or unusual
  characters. A secret key is arbitrary, user-chosen text meant to resemble
  an environment-variable name — `db.password`, `my-key`, `DATABASE_URL` are
  all legitimate, and mixed case, dots, and dashes are all plausible. An
  allowlist strict enough to be meaningful would reject real keys; the wiki
  enumerates exactly four denied sequences (empty, `/`, `\\`, a null byte,
  `..`) plus a length cap, and this module implements exactly those — no
  more, no less. Tightening beyond `SEC-A10` is out of this ticket's scope
  by design, not an oversight.

  ## No casing rule, and that is also deliberate

  `validate/1` does not constrain a key's casing. The rule considered and
  rejected was "lowercase except the last, uppercase segment" — meant to
  mirror the `DATABASE_URL`-style convention used by the seeded fixtures and
  real Parameter Store keys. It was rejected because the risk is not
  symmetric: a validator that wrongly rejects a legitimate key does not stop
  an operator, it routes them around Nucleus entirely — straight to the AWS
  console, where nothing is audited and no `secret_created` event exists.
  Wrongly permissive costs a cosmetically inconsistent key name; wrongly
  strict costs audit coverage that cannot be reconstructed after the fact.
  Parameter Store is also not exclusively Nucleus's — keys created by
  Terraform, the console, or any other tooling can be any casing, and
  `Nucleus.Secrets.list/2` already sorts case-insensitively
  (`&{String.downcase(&1.key), &1.key}`) to cope with that. A create-only
  casing rule would produce a list showing `api-key` next to a form that
  refuses to create it. The convention is expressed as guidance in the
  creation form (a placeholder and a hint), not enforcement here.

  ## The 256-character cap applies to every caller, including reads

  `validate/1` is the single gate for `create/4`, `reveal/3`, and `update/4`
  alike — there is one rule set, not a stricter create-time rule layered on
  a looser read-time one. The deliberate consequence: a key longer than 256
  characters, created outside Nucleus (Parameter Store enforces its own,
  much longer limit), would be listable by `Nucleus.Secrets.list/2` — which
  calls no per-key validation, only `Store.list_secrets/1` — but rejected by
  `reveal/3` and `update/4`, which both call `validate/1` before reaching the
  store. This is accepted, not a bug: a list-then-reveal path with a
  since-created oversized key visibly fails at reveal, rather than silently
  succeeding against a rule this module does not enforce for reads and
  writes differently.

  ## Distinct reason atoms, not a single generic message

  `SEC-A10` requires the form "clearly indicate the specific problem" — one
  generic "invalid key" message does not satisfy that. `validate/1` returns
  `Nucleus.Backend.Error.t()`, matching `Nucleus.Secrets.Value.validate/1`'s
  shape (see
  `docs/adr/0013-secret-edit-in-modal-and-value-form.md`'s addendum) so
  `create/4`'s `with` chain needs no special case for either sibling
  validator's failure. The per-rule distinction lives in
  `error.details.reason` — one of `:empty`, `:too_long`, `:forward_slash`,
  `:backslash`, `:null_byte`, `:path_traversal` — while `error.message`
  carries the human-readable copy a form can show directly.

  Checked in a fixed order, so a key violating more than one rule always
  reports the same reason rather than one that depends on how the checks
  happen to be listed: empty/whitespace-only, then path traversal, then
  forward slash, then backslash, then a null byte, then the length cap.
  Path traversal is checked before forward slash specifically because
  `"../x"` contains both `..` and `/` — checking slash first would report
  the less specific rule for a key that is unambiguously a traversal
  attempt.
  """

  alias Nucleus.Backend.Error
  alias Nucleus.Secrets.Store

  @max_length 256

  @doc """
  The maximum number of characters a secret key may contain.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Validates `key`'s shape: non-empty (and not whitespace-only), at most
  #{@max_length} characters (`String.length/1`, not `byte_size/1`), and free
  of `/`, `\\`, a null byte, and `..`.

  Accepts `term()`, not just `String.t()` — a key arriving from a
  client-controlled form param has not been shown to be a string yet.

      iex> Nucleus.Secrets.Key.validate("DATABASE_URL")
      :ok

      iex> Nucleus.Secrets.Key.validate("db.password")
      :ok

      iex> {:error, error} = Nucleus.Secrets.Key.validate("")
      iex> error.details.reason
      :empty

      iex> {:error, error} = Nucleus.Secrets.Key.validate("a/b")
      iex> error.details.reason
      :forward_slash

      iex> {:error, error} = Nucleus.Secrets.Key.validate("../x")
      iex> error.details.reason
      :path_traversal

      iex> {:error, error} = Nucleus.Secrets.Key.validate(String.duplicate("a", 257))
      iex> error.details.reason
      :too_long
  """
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(key) when is_binary(key) do
    cond do
      String.trim(key) == "" ->
        invalid(:empty, "secret key must not be empty", key)

      String.contains?(key, "..") ->
        invalid(
          :path_traversal,
          "secret key must not contain a path-traversal sequence (\"..\")",
          key
        )

      String.contains?(key, "/") ->
        invalid(:forward_slash, "secret key must not contain a forward slash (\"/\")", key)

      String.contains?(key, "\\") ->
        invalid(:backslash, "secret key must not contain a backslash (\"\\\")", key)

      String.contains?(key, <<0>>) ->
        invalid(:null_byte, "secret key must not contain a null byte", key)

      String.length(key) > @max_length ->
        invalid(:too_long, "secret key exceeds #{@max_length} characters", key, %{
          length: String.length(key)
        })

      true ->
        :ok
    end
  end

  def validate(other) do
    invalid(:not_a_string, "secret key must be a string", other)
  end

  defp invalid(reason, message, key, extra_details \\ %{}) do
    details = Map.merge(%{reason: reason, key: inspect(key)}, extra_details)
    {:error, Error.new(:invalid, Store.boundary(), message, details)}
  end
end
