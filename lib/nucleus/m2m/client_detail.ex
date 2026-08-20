defmodule Nucleus.M2M.ClientDetail do
  @moduledoc """
  One M2M client's detail view, deliberately with no secret field.

  `DescribeUserPoolClient` returns the client secret in plaintext
  (`"ClientSecret"` on `user_pool_client_type`) alongside everything else this
  struct needs. `M2M-A03` forbids showing the secret on the detail view, and
  this feature has no "retrieve an existing secret" operation at all, so the
  secret is dropped at the Cognito adapter's edge — this struct simply has
  nowhere to put it, the same structural defence `Nucleus.Secrets.SecretRef`
  gives `SEC-A01`. Add a test asserting
  `refute Map.has_key?(detail, :client_secret)` so a future struct merge
  breaks loudly here rather than quietly on the detail view.

  `token_validity_seconds` is seconds, not minutes, deliberately: it is the
  unit Cognito's own `AccessTokenValidity` range is expressed in, and it
  stays lossless for a client this feature didn't create (a Terraform-managed
  client can have a 24-hour or a non-round-minute validity). The operator's
  own input unit at creation is minutes
  (`Nucleus.M2M.Clients.create_client/2`'s `token_validity_minutes`) — the
  operator's unit, not this struct's storage unit.
  """

  @enforce_keys [:client_id, :client_name, :scope, :token_validity_seconds]
  defstruct [:client_id, :client_name, :scope, :token_validity_seconds, :created_date]

  @type t :: %__MODULE__{
          client_id: String.t(),
          client_name: String.t(),
          scope: String.t(),
          token_validity_seconds: pos_integer(),
          created_date: DateTime.t() | nil
        }
end
