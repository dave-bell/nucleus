defmodule NucleusWeb.SecretsLive.CreateForm do
  @moduledoc """
  The changeset backing `SEC-A09`'s creation form — a key and a value.

  An `embedded_schema` with `:key` and `:value` fields, following
  `NucleusWeb.SecretsLive.EditForm`'s shape exactly (`docs/adr/0013-secret-edit-in-modal-and-value-form.md`):
  no repo, per `AGENTS.md`'s Ecto guideline that `Ecto.Changeset` is retained
  for form validation with no database involved. This was the pattern that
  ADR-0013 established specifically so this form would not have to invent
  one.

  `changeset/3` runs `Nucleus.Secrets.Key.validate/1` and
  `Nucleus.Secrets.Value.validate/1` — the same functions
  `Nucleus.Secrets.create/4` calls before ever reaching the store — via
  `validate_change/3`, so the inline error a user sees while typing and the
  error the context function would return on submission are always the same
  text for both fields. There is deliberately no second copy of any of
  `Key`'s six rules or `Value`'s two here.

  ## Duplicate detection is case-sensitive, and lives here, not in `Key`

  `Nucleus.Secrets.Key.validate/1` has no view of the other keys already in
  this environment — it is a pure shape check. `SEC-A10`'s "duplicates an
  existing key in this environment" is checked here, against the
  `existing_keys` list the LiveView passes in from its already-loaded
  stream, and compared with `in/2` (exact, case-sensitive): Parameter Store
  paths are themselves case-sensitive, so `API_KEY` and `api_key` are
  genuinely different secrets, and a case-insensitive check here would block
  a legal key. This is advisory only — `SEC-A12`'s server-side
  `:already_exists` rejection is the authoritative, race-safe check; this
  form-side check exists purely for `SEC-A10`'s fast feedback while typing.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Nucleus.Backend.Error
  alias Nucleus.Secrets.Key
  alias Nucleus.Secrets.Value

  @primary_key false
  embedded_schema do
    field :key, :string
    field :value, :string
  end

  @doc """
  Builds a changeset from `attrs` (string-keyed form params, e.g.
  `%{"key" => "...", "value" => "..."}`), validating `:key` against
  `existing_keys` for `SEC-A10`'s duplicate check.
  """
  @spec changeset(t :: Ecto.Schema.t(), attrs :: map(), existing_keys :: [String.t()]) ::
          Ecto.Changeset.t()
  def changeset(form, attrs, existing_keys \\ []) do
    form
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value], message: "can't be blank")
    |> validate_change(:key, &validate_secret_key/2)
    |> validate_change(:key, fn :key, key -> validate_duplicate_key(key, existing_keys) end)
    |> validate_change(:value, &validate_secret_value/2)
  end

  # Emptiness is `validate_required/3`'s job, above — skipped here so a blank
  # key or value shows exactly one error, not "can't be blank" stacked on
  # top of `Key`/`Value`'s own empty-input message.
  defp validate_secret_key(:key, ""), do: []

  defp validate_secret_key(:key, key) do
    case Key.validate(key) do
      :ok -> []
      {:error, %Error{message: message}} -> [key: message]
    end
  end

  defp validate_duplicate_key("", _existing_keys), do: []

  defp validate_duplicate_key(key, existing_keys) do
    if key in existing_keys do
      [key: "already exists in this environment"]
    else
      []
    end
  end

  defp validate_secret_value(:value, ""), do: []

  defp validate_secret_value(:value, value) do
    case Value.validate(value) do
      :ok -> []
      {:error, %Error{message: message}} -> [value: message]
    end
  end
end
