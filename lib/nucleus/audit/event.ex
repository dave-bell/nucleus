defmodule Nucleus.Audit.Event do
  @moduledoc """
  The one record shape every audited action produces.

  This struct — and the catalogue below it — is the AUD-A02 defence: there is
  no field named `value`, `secret`, `plaintext`, or `new_value`, so a call site
  cannot pass a secret value through by accident. `resource` carries *what was
  accessed* (a path or key), never the value itself.

  The `event` type union covers all eleven events from the wiki's
  [Audit & Compliance](https://github.com/dave-bell/nucleus/wiki/Audit-and-Compliance)
  catalogue, so later features do not each invent their own spelling. Only the
  three Secrets events (`:secret_created`, `:secret_viewed`, `:secret_updated`)
  are wired to a call site today — see `docs/requirements/Audit-and-Compliance.md`
  for the full table this catalogue is built from.

  Fields the catalogue lists that have no dedicated struct field (`path`,
  `key`, `added`, `removed`, `client_name`, `ticket_id`) live in `details`,
  which is key-allowlisted per event by `catalogue/0` — a free-form
  `details: map()` would reopen exactly the hole the struct closes, since
  nothing would stop a `value` key from hiding inside it.
  """

  @type event ::
          :auth_failure
          | :nomad_vars_listed
          | :nomad_var_viewed
          | :nomad_var_updated
          | :env_names_updated
          | :secret_created
          | :secret_viewed
          | :secret_updated
          | :m2m_client_viewed
          | :m2m_client_created
          | :m2m_secret_rotated

  @type t :: %__MODULE__{
          event: event(),
          user: String.t(),
          tenant: String.t() | nil,
          timestamp: DateTime.t(),
          source_ip: String.t() | nil,
          resource: String.t() | nil,
          reason: String.t() | nil,
          details: map()
        }

  @derive {Jason.Encoder,
           only: [:event, :user, :tenant, :timestamp, :source_ip, :resource, :reason, :details]}
  @enforce_keys [:event, :user, :timestamp]
  defstruct [:event, :user, :tenant, :timestamp, :source_ip, :resource, :reason, details: %{}]

  # Per-event field lists. `allowed` are the keyword keys `Nucleus.Audit.emit/2`
  # accepts for that event (beyond `:user`, which every event accepts and
  # defaults from); `required` is the subset that must be present and
  # non-nil. `details_allowed`/`details_required` are the same two ideas, one
  # level down, for keys inside the `details` map.
  #
  # Built directly from the wiki catalogue table — do not invent a field here
  # that table does not list.
  @catalogue %{
    auth_failure: %{
      allowed: [:user, :tenant, :source_ip, :reason, :details],
      required: [:tenant, :reason],
      details_allowed: [:path],
      details_required: [:path]
    },
    nomad_vars_listed: %{
      allowed: [:user, :tenant, :details],
      required: [:tenant],
      details_allowed: [:path],
      details_required: [:path]
    },
    nomad_var_viewed: %{
      allowed: [:user, :tenant, :details],
      required: [:tenant],
      details_allowed: [:path, :key],
      details_required: [:path, :key]
    },
    nomad_var_updated: %{
      allowed: [:user, :tenant, :details],
      required: [:tenant],
      details_allowed: [:path, :key],
      details_required: [:path, :key]
    },
    env_names_updated: %{
      allowed: [:user, :tenant, :details],
      required: [:tenant],
      details_allowed: [:path, :added, :removed],
      details_required: [:path, :added, :removed]
    },
    secret_created: %{
      allowed: [:user, :tenant, :resource],
      required: [:tenant, :resource],
      details_allowed: [],
      details_required: []
    },
    secret_viewed: %{
      allowed: [:user, :tenant, :resource],
      required: [:tenant, :resource],
      details_allowed: [],
      details_required: []
    },
    secret_updated: %{
      allowed: [:user, :tenant, :resource],
      required: [:tenant, :resource],
      details_allowed: [],
      details_required: []
    },
    m2m_client_viewed: %{
      allowed: [:user, :tenant, :details],
      required: [:tenant],
      details_allowed: [:client_name],
      details_required: [:client_name]
    },
    m2m_client_created: %{
      allowed: [:user, :tenant, :details],
      required: [:tenant],
      details_allowed: [:client_name, :ticket_id],
      details_required: [:client_name, :ticket_id]
    },
    m2m_secret_rotated: %{
      allowed: [:user, :tenant, :details],
      required: [:tenant],
      details_allowed: [:client_name],
      details_required: [:client_name]
    }
  }

  @doc """
  Every catalogued event, so a caller (or a test) can assert exhaustive
  handling instead of guessing at the union.

      iex> :secret_viewed in Nucleus.Audit.Event.events()
      true
  """
  @spec events() :: [event()]
  def events, do: Map.keys(@catalogue)

  @doc """
  Whether `event` is in the catalogue.

      iex> Nucleus.Audit.Event.known?(:secret_viewed)
      true

      iex> Nucleus.Audit.Event.known?(:secret_view)
      false
  """
  @spec known?(term()) :: boolean()
  def known?(event), do: is_map_key(@catalogue, event)

  @doc """
  The field spec for `event`: `%{allowed:, required:, details_allowed:, details_required:}`.

  Raises `KeyError` for an unknown event — callers must check `known?/1` first,
  which is exactly what `Nucleus.Audit.emit/2` does before calling this.
  """
  @spec spec(event()) :: %{
          allowed: [atom()],
          required: [atom()],
          details_allowed: [atom()],
          details_required: [atom()]
        }
  def spec(event), do: Map.fetch!(@catalogue, event)
end
