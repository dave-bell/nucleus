defmodule NucleusWeb.SecretsLive.EditForm do
  @moduledoc """
  The changeset backing `SEC-A06`'s edit-value form.

  An `embedded_schema` with a single `:value` field — no repo, per
  `AGENTS.md`'s Ecto guideline that `Ecto.Changeset` is retained for form
  validation with no database involved. This is the first form this
  application has needed; `SEC-S6`'s creation form is expected to follow the
  same shape for its own value field.

  `changeset/2` runs `Nucleus.Secrets.Value.validate/1` — the same function
  `Nucleus.Secrets.update/4` calls before ever reaching the store — via
  `validate_change/3`, so the inline error a user sees while typing and the
  error the context function would return on submission are always the same
  text. There is deliberately no second copy of "must not be empty" or
  "exceeds 4096 characters" here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Nucleus.Backend.Error
  alias Nucleus.Secrets.Value

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
    |> validate_change(:value, &validate_secret_value/2)
  end

  # Emptiness is `validate_required/3`'s job, above — skipped here so a blank
  # value shows exactly one error, not "can't be blank" and "must not be
  # empty" stacked on the same field.
  defp validate_secret_value(:value, ""), do: []

  defp validate_secret_value(:value, value) do
    case Value.validate(value) do
      :ok -> []
      {:error, %Error{message: message}} -> [value: message]
    end
  end
end
