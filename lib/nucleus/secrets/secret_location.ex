defmodule Nucleus.Secrets.SecretLocation do
  @moduledoc """
  Where a secret lives, without its value: a Parameter Store path and ARN.

  Exists so that ARN construction — which requires an AWS account ID — lives
  behind the boundary rather than in a LiveView. Wiki ADR-0007 records that in
  the prototype this was a module-level `boto3` call inside route code,
  bypassing the plugin layer entirely: the canonical example of the leaky
  abstraction `docs/adr/0002-backend-adapter-boundaries.md` exists to prevent.
  A LiveView must never know what an AWS account ID is; it asks
  `Nucleus.Secrets.Store.locate_secret/2` instead.
  """

  @enforce_keys [:path, :arn]
  defstruct [:path, :arn]

  @type t :: %__MODULE__{
          path: String.t(),
          arn: String.t()
        }
end
