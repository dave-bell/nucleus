defmodule Nucleus.Secrets.SecretRef do
  @moduledoc """
  A secret's metadata, deliberately with no `value` field.

  `SEC-A01` requires that a secret listing never includes the plaintext value —
  "values are masked by default — they are never included in the listing
  response." Masking a value in a template is a rule someone can forget to
  apply; a struct that has nowhere to put the value makes the mistake
  impossible to make. `Nucleus.Secrets.Store.list_secrets/1`,
  `list_environments/0`'s companion `list_all_secrets/0`, `create_secret/3` and
  `update_secret/3` all return this struct, never `Nucleus.Secrets.Secret`.

  `SEC-S2` asserts this structurally. Do not add a `value` field here, and do
  not merge this struct with `Nucleus.Secrets.Secret` — see that module's
  `@moduledoc` for why they stay separate.
  """

  @enforce_keys [:key, :path, :arn]
  defstruct [:key, :path, :arn, :last_modified]

  @type t :: %__MODULE__{
          key: String.t(),
          path: String.t(),
          arn: String.t(),
          last_modified: DateTime.t() | nil
        }
end
