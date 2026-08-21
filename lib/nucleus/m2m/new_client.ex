defmodule Nucleus.M2M.NewClient do
  @moduledoc """
  The changeset backing the M2M client creation form — `M2M-A04`–`A07`.

  An `embedded_schema` with `:ticket_id`, `:purpose`, and
  `:access_token_validity_minutes` — no repo, per `AGENTS.md`'s Ecto
  guideline that `Ecto.Changeset` is retained for form validation with no
  database involved, following `NucleusWeb.SecretsLive.CreateForm`'s shape
  exactly (`docs/adr/0013-secret-edit-in-modal-and-value-form.md`).

  `changeset/2` runs `Nucleus.M2M.TicketId.validate/1` and
  `Nucleus.M2M.Purpose.validate/1` — the same functions the eventual create
  path (M2M-S5) calls before ever reaching `Nucleus.M2M.ClientName.build/2`
  — via `validate_change/3`, mapping each reason atom to its own message so
  the inline error a user sees while typing matches `M2M-A05`/`A06`'s
  "indicates the problem" obligation. There is deliberately no second copy
  of any of `TicketId`'s three rules or `Purpose`'s five here — the mapping
  from reason atom to copy lives once, in `ticket_id_message/1` and
  `purpose_message/1` below, so the wording is reviewable as a set.

  ## `:empty` has no message of its own

  `validate_required/3` already produces "can't be blank" for a missing
  `:ticket_id`/`:purpose` before `validate_change/3` ever runs its callback
  for that field, and the callbacks below skip an empty string outright
  (`ticket_id_message`/`purpose_message` are never called for `:empty`) — a
  blank field shows exactly one error, not `TicketId`/`Purpose`'s own empty
  message stacked on top of `validate_required/3`'s.

  ## No duplicate-name check here

  `M2M-A09` is removed, not deferred — Cognito does not enforce
  `ClientName` uniqueness (`docs/adr/0016-m2m-client-adapter.md`), so there
  is nothing for this form to check against. `Nucleus.M2M.ClientName.build/2`
  concatenates verbatim once both fields are valid; nothing here previews a
  name that has not passed both validators.

  ## `:access_token_validity_minutes` is not validated here

  `M2M-S4` (this module) gains the field on the form, pre-filled at 15
  minutes — [EN-10 Decision 4](https://github.com/dave-bell/nucleus/issues/33#issuecomment-5349942648).
  The range check (`M2M-A17`, a whole number of minutes from 5 to 60
  inclusive) is explicitly claimed by M2M-S5
  (https://github.com/dave-bell/nucleus/issues/38#issuecomment-5350929501),
  which re-validates server-side before `create_client/2` runs. This
  changeset casts the field so the form can bind and pre-fill it, and
  nothing else — do not add a range check here without first re-reading
  that decision.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Nucleus.M2M.Purpose
  alias Nucleus.M2M.TicketId

  @default_token_validity_minutes 15

  @primary_key false
  embedded_schema do
    field :ticket_id, :string
    field :purpose, :string
    field :access_token_validity_minutes, :integer, default: @default_token_validity_minutes
  end

  @doc """
  The default access token validity, in minutes, the form pre-fills
  (`M2M-A04`).
  """
  @spec default_token_validity_minutes() :: pos_integer()
  def default_token_validity_minutes, do: @default_token_validity_minutes

  @doc """
  Builds a changeset from `attrs` (string-keyed form params, e.g.
  `%{"ticket_id" => "...", "purpose" => "...", "access_token_validity_minutes" => "15"}`).
  """
  @spec changeset(form :: Ecto.Schema.t(), attrs :: map()) :: Ecto.Changeset.t()
  def changeset(form, attrs) do
    form
    |> cast(attrs, [:ticket_id, :purpose, :access_token_validity_minutes])
    |> validate_required([:ticket_id, :purpose], message: "can't be blank")
    |> validate_change(:ticket_id, &validate_ticket_id/2)
    |> validate_change(:purpose, &validate_purpose/2)
  end

  defp validate_ticket_id(:ticket_id, ""), do: []

  defp validate_ticket_id(:ticket_id, ticket_id) do
    case TicketId.validate(ticket_id) do
      :ok -> []
      {:error, reason} -> [ticket_id: ticket_id_message(reason)]
    end
  end

  defp validate_purpose(:purpose, ""), do: []

  defp validate_purpose(:purpose, purpose) do
    case Purpose.validate(purpose) do
      :ok -> []
      {:error, reason} -> [purpose: purpose_message(reason)]
    end
  end

  # `:empty` is deliberately absent — `validate_required/3` already covers
  # it, and the callbacks above never call this with an empty string.
  defp ticket_id_message(:too_long) do
    "must be #{TicketId.max_length()} characters or fewer"
  end

  defp ticket_id_message(:format) do
    "must be uppercase letters, a hyphen, then digits (e.g. OPS-1234)"
  end

  defp purpose_message(:too_long) do
    "must be #{Purpose.max_length()} characters or fewer"
  end

  defp purpose_message(:charset) do
    "must contain only lowercase letters, digits, and hyphens"
  end

  defp purpose_message(:leading_hyphen), do: "cannot start with a hyphen"
  defp purpose_message(:trailing_hyphen), do: "cannot end with a hyphen"
end
