defmodule Nucleus.M2M.ClientCredentials do
  @moduledoc """
  A client's secret, shown exactly once — at creation or at rotation, and
  **never** at any other time. Returned by `create_client/2` and
  `rotate_secret/1`, and nothing else, ever.

  Client secrets follow an AWS IAM-style security model: there is no
  "retrieve an existing secret" operation, so the only two moments this
  struct is ever built are the two moments a secret legitimately needs
  revealing. Do not reuse this struct, or a field shaped like it, for any
  other response.

  `@derive {Inspect, except: [:client_secret]}` so an accidental `inspect/1`
  in a log line or a crash report cannot print the secret — the same
  discipline `Nucleus.M2M.Clients.Cognito`'s moduledoc requires of its own
  logging, extended to cover a default `Inspect` implementation nobody
  wrote on purpose.
  """

  @derive {Inspect, except: [:client_secret]}
  @enforce_keys [:client_id, :client_name, :client_secret]
  defstruct [:client_id, :client_name, :client_secret]

  @type t :: %__MODULE__{
          client_id: String.t(),
          client_name: String.t(),
          client_secret: String.t()
        }
end
