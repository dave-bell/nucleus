defmodule Nucleus.Secrets.Secret do
  @moduledoc """
  A secret's metadata *plus* its plaintext value.

  Only ever produced by `Nucleus.Secrets.Store.get_secret/2` — the one
  operation `SEC-A03` defines as an explicit, audited reveal
  (`secret_viewed`). Every other callback on the boundary returns
  `Nucleus.Secrets.SecretRef`, which has no `value` field at all.

  **Deliberately not merged with `SecretRef`.** A single struct carrying an
  optional value would make a future `<%= @secret.value %>` a silent leak the
  first time it was called on data that came from a listing rather than a
  reveal — the two structs exist so that mistake cannot compile against the
  wrong data. See `Nucleus.Secrets.SecretRef` for the fuller rationale.
  """

  @enforce_keys [:key, :path, :arn, :value]
  defstruct [:key, :path, :arn, :value, :last_modified]

  @type t :: %__MODULE__{
          key: String.t(),
          path: String.t(),
          arn: String.t(),
          value: String.t(),
          last_modified: DateTime.t() | nil
        }
end
