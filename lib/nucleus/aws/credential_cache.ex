defmodule Nucleus.Aws.CredentialCache do
  @moduledoc """
  Cached assumed-role credentials, keyed on the assume-role request that
  produced them.

  `:persistent_term` rather than a supervised `Agent`: credentials are
  written once every ~55 minutes (the STS session lifetime minus a safety
  skew) and read on every call, which is precisely the read-heavy/write-rare
  shape `:persistent_term` is for. There is nothing here for a supervisor to
  restart — a crash loses nothing that a re-`assume_role` on the next call
  would not recover anyway.

  **Keyed, not a single slot.** `Nucleus.Secrets.Store.Aws` and (from EN-10)
  `Nucleus.M2M.Clients.Cognito` both assume a role, and the two role ARNs are
  independent configuration — a single slot would hand one boundary's
  credentials to the other. The key is `{role_arn, external_id,
  session_name}`: the assume-role *request*, not the caller. Configure both
  boundaries with the same ARN and the keys collapse to one slot and one
  `AssumeRole` cadence; configure them differently and each gets its own
  slot. Keys stay bounded by configuration (currently two), so
  `:persistent_term`'s write-time global scan remains a non-issue at hourly
  writes.

  **This caches credentials, not secret values.** It does not violate the
  stateless constraint (`docs/adr/0001-no-local-datastore.md`), which is
  about tenant configuration data, not ambient AWS session tokens.
  """

  @type key ::
          {role_arn :: String.t(), external_id :: String.t() | nil, session_name :: String.t()}

  @doc """
  The cached credentials for `key`, or `nil` if nothing has been cached yet.
  """
  @spec get(key()) :: map() | nil
  def get(key), do: :persistent_term.get(cache_key(key), nil)

  @doc """
  Caches `credentials` under `key`, replacing whatever was cached before for
  that key. Other keys are untouched.
  """
  @spec put(key(), map()) :: :ok
  def put(key, credentials) when is_map(credentials) do
    :persistent_term.put(cache_key(key), credentials)
    :ok
  end

  @doc """
  Clears the cache slot for `key`. Other keys are untouched.

  Called on any credential-expiry-shaped AWS error, so the next call for
  *that key* re-`assume_role`s rather than retrying with what AWS just
  rejected — the invalidation `SEC-A18` needs to make "a fresh attempt after
  re-authentication succeeds normally" true. Clearing by key, rather than
  clearing everything, means an `ExpiredToken` run on one boundary does not
  churn another boundary's perfectly good credentials. Also used by tests to
  reset state between examples.
  """
  @spec clear(key()) :: :ok
  def clear(key) do
    :persistent_term.erase(cache_key(key))
    :ok
  end

  defp cache_key(key), do: {__MODULE__, key}
end
