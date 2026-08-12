defmodule Nucleus.Secrets.Store.Aws.CredentialCache do
  @moduledoc """
  The one cached value for `Nucleus.Secrets.Store.Aws`: the tenant's assumed
  role credentials, plus the tenant's account ID fetched alongside them.

  Keyed on nothing — there is exactly one tenant per deployment, so there is
  exactly one cache slot, not a table. `:persistent_term` rather than a
  supervised `Agent`: credentials are written once every ~55 minutes (the STS
  session lifetime minus a safety skew) and read on every Parameter Store
  call, which is precisely the read-heavy/write-rare shape `:persistent_term`
  is for. There is nothing here for a supervisor to restart — a crash loses
  nothing that a re-`assume_role` on the next call would not recover anyway.

  **This caches credentials, not secret values.** It does not violate the
  stateless constraint (`docs/adr/0001-no-local-datastore.md`), which is about
  tenant configuration data, not ambient AWS session tokens.
  """

  @key {__MODULE__, :credentials}

  @doc """
  The cached credentials, or `nil` if nothing has been cached yet.
  """
  @spec get() :: map() | nil
  def get, do: :persistent_term.get(@key, nil)

  @doc """
  Caches `credentials`, replacing whatever was cached before.
  """
  @spec put(map()) :: :ok
  def put(credentials) when is_map(credentials) do
    :persistent_term.put(@key, credentials)
    :ok
  end

  @doc """
  Clears the cache.

  Called on any credential-expiry-shaped AWS error, so the next call
  re-`assume_role`s rather than retrying with what AWS just rejected —
  the invalidation `SEC-A18` needs to make "a fresh attempt after
  re-authentication succeeds normally" true. Also used by tests to reset
  state between examples.
  """
  @spec clear() :: :ok
  def clear do
    :persistent_term.erase(@key)
    :ok
  end
end
