defmodule Nucleus.NomadVars.VariableSet do
  @moduledoc """
  Everything `Nucleus.NomadVars.Store.read/0` and `.write/2` return: the full
  `Items` map for one Nomad Variables path, plus the metadata needed for a
  safe check-and-set retry.

  ## One `modify_index`/`modified_at` for the whole set, not per key

  Nomad Variables are path-addressed: one path holds an `Items` map for
  *every* key, with a single `ModifyIndex` and `ModifyTime` for the whole
  path — there is no per-key timestamp Nomad's API returns. The wiki's
  `{ variables: [{ key, value, last_modified }] }` shape
  (`Data-Export-Configuration.md:175`) cannot actually be built from a real
  Nomad response; manufacturing a per-key timestamp would misrepresent data
  Nomad does not give us. DEX-D1 amends the wiki to match this struct.
  """

  @enforce_keys [:path, :items, :modify_index]
  defstruct [:path, :items, :modify_index, :modified_at]

  @type t :: %__MODULE__{
          path: String.t(),
          items: %{String.t() => String.t()},
          modify_index: non_neg_integer(),
          modified_at: DateTime.t() | nil
        }
end
