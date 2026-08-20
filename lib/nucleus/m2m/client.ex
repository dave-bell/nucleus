defmodule Nucleus.M2M.Client do
  @moduledoc """
  One M2M client's row on the list, deliberately with no secret field.

  `ListUserPoolClients` does not return a creation date at all — Cognito's
  `user_pool_client_description` is `ClientId`/`ClientName`/`UserPoolId`, full
  stop — so `Nucleus.M2M.Clients.Cognito.list_clients/0` fans out one
  `DescribeUserPoolClient` per client to fill `created_date` in
  ([Decision 6](https://github.com/dave-bell/nucleus/issues/33#issuecomment-5349943455)).
  That per-client describe can itself fail — the client was deleted between
  the two calls, or the request was throttled — and a single bad row must not
  take down the whole list. `created_date` and `created_date_error` carry
  that: exactly one of them is non-nil for any given `Client`.

  `client_id` is this client's real identifier, not `client_name` — Cognito
  does not require client names to be unique, so two rows can share a name
  (`M2M-A01`, wiki).
  """

  @enforce_keys [:client_id, :client_name]
  defstruct [:client_id, :client_name, :created_date, :created_date_error]

  @type t :: %__MODULE__{
          client_id: String.t(),
          client_name: String.t(),
          created_date: DateTime.t() | nil,
          created_date_error: Nucleus.Backend.Error.kind() | nil
        }
end
