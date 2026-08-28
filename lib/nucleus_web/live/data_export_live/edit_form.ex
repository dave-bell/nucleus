defmodule NucleusWeb.DataExportLive.EditForm do
  @moduledoc """
  The changeset backing `DEX-A04`/`DEX-A05`'s inline edit form.

  An `embedded_schema` with a single `:value` field, no repo — the same
  shape `NucleusWeb.SecretsLive.EditForm` uses for `SEC-A06`
  (`lib/nucleus_web/live/secrets_live/edit_form.ex`), the mechanics this
  ticket's plan says to mirror. Sibling of that module, not a reuse across
  boundaries — different domain (`Nucleus.NomadVars.Value`, not
  `Nucleus.Secrets.Value`), same rule shape.

  `changeset/2` runs `Nucleus.NomadVars.Value.validate/1` via
  `validate_change/3`, so the inline error shown while typing and the error
  `Nucleus.NomadVars.update/5` would enforce on submission are always the
  same rule — there is deliberately no second copy of "must not be empty"
  or "exceeds 4096 characters" here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Nucleus.NomadVars.Value

  @primary_key false
  embedded_schema do
    field :value, :string
  end

  @doc """
  Builds a changeset from `attrs` (string-keyed form params, e.g.
  `%{"value" => "..."}`).
  """
  @spec changeset(t :: Ecto.Schema.t(), attrs :: map()) :: Ecto.Changeset.t()
  def changeset(form, attrs) do
    form
    |> cast(attrs, [:value])
    |> validate_required([:value], message: "can't be blank")
    |> validate_change(:value, &validate_value/2)
  end

  # Emptiness is `validate_required/3`'s job, above — skipped here so a
  # blank value shows exactly one error, not "can't be blank" and "must not
  # be empty" stacked on the same field.
  defp validate_value(:value, ""), do: []

  defp validate_value(:value, value) do
    case Value.validate(value) do
      :ok -> []
      {:error, :empty} -> [value: "can't be blank"]
      {:error, :too_long} -> [value: "must be #{Value.max_length()} characters or fewer"]
    end
  end
end
