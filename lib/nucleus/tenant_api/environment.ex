defmodule Nucleus.TenantApi.Environment do
  @moduledoc """
  One of the tenant's deployment stages, as reported by their backing API.

  Nucleus does not own environments (`ENV-A07`) — it reads them live and
  displays them. This struct is the shape the rest of the application sees.

  ## Translation happens here, once

  The backing API speaks camelCase (`shortName`, `accentColor`, `isArchived`);
  this codebase is snake_case, and a boolean reads as a predicate (`archived?`)
  per `AGENTS.md`. `from_api/1` is the only place that translation happens, and
  both `Nucleus.TenantApi.Http` and `Nucleus.TenantApi.Local` go through it —
  which is also what stops the two implementations drifting apart on shape. No
  camelCase key reaches a LiveView or a template.

  ## `short_name` is enforced

  `short_name` is the URL path segment *and* a Parameter Store path segment. An
  `%Environment{}` carrying `nil` there would build a path that silently
  addresses the wrong thing, so it is an enforced key: the struct cannot be
  constructed without one. `from_api/1` rejects a missing or blank value rather
  than defaulting it, and its callers fail the whole call rather than dropping
  the element (see `Nucleus.TenantApi.Http`).

  ## One absence case per field

  Optional strings are `nil` when the API omits them *or* sends a blank string,
  so a caller has exactly one absence to handle. `ENV-A02` requires a
  description be "shown when the environment has one, and omitted when it does
  not" — a template testing both `nil` and `""` is a template that will
  eventually test only one.

  `categories` is always a list of strings, never `nil`, for the same reason.
  """

  @enforce_keys [:short_name]
  defstruct [
    :short_name,
    :label,
    :iri,
    :accent_color,
    :description,
    categories: [],
    archived?: false
  ]

  @type t :: %__MODULE__{
          short_name: String.t(),
          label: String.t() | nil,
          iri: String.t() | nil,
          accent_color: String.t() | nil,
          description: String.t() | nil,
          categories: [String.t()],
          archived?: boolean()
        }

  @type reason ::
          :not_an_object
          | :missing_short_name
          | :invalid_label
          | :invalid_iri
          | :invalid_accent_color
          | :invalid_description
          | :invalid_categories
          | :invalid_archived

  @doc """
  Builds an `%Environment{}` from one decoded API object.

  Returns `{:error, reason}` on anything unexpected rather than guessing. The
  caller turns the reason into a `Nucleus.Backend.Error` in its own boundary's
  vocabulary, because this module has no opinion about whether a bad payload is
  `:unavailable` or something else.

      iex> {:ok, env} = Nucleus.TenantApi.Environment.from_api(%{"shortName" => "prod", "description" => ""})
      iex> {env.short_name, env.description, env.categories, env.archived?}
      {"prod", nil, [], false}

      iex> Nucleus.TenantApi.Environment.from_api(%{"label" => "Production"})
      {:error, :missing_short_name}
  """
  @spec from_api(map()) :: {:ok, t()} | {:error, reason()}
  def from_api(%{} = attrs) do
    with {:ok, short_name} <- required_string(attrs, "shortName", :missing_short_name),
         {:ok, label} <- optional_string(attrs, "label", :invalid_label),
         {:ok, iri} <- optional_string(attrs, "iri", :invalid_iri),
         {:ok, accent_color} <- optional_string(attrs, "accentColor", :invalid_accent_color),
         {:ok, description} <- optional_string(attrs, "description", :invalid_description),
         {:ok, categories} <- categories(attrs),
         {:ok, archived?} <- archived(attrs) do
      {:ok,
       %__MODULE__{
         short_name: short_name,
         label: label,
         iri: iri,
         accent_color: accent_color,
         description: description,
         categories: categories,
         archived?: archived?
       }}
    end
  end

  def from_api(_other), do: {:error, :not_an_object}

  @doc """
  Builds a list of environments, failing on the first unusable element.

  **All or nothing, deliberately.** Returning the elements that happened to
  parse would hand a caller a list that is quietly missing an environment — and
  the caller has no way to tell a tenant with four environments from a tenant
  with five and one bad record. `SEC-A15`–`A17` want a definite answer or a
  definite failure; a plausible-looking subset is neither.

      iex> {:ok, envs} = Nucleus.TenantApi.Environment.from_api_list([%{"shortName" => "prod"}])
      iex> Enum.map(envs, & &1.short_name)
      ["prod"]

      iex> Nucleus.TenantApi.Environment.from_api_list([%{"shortName" => "prod"}, %{"shortName" => " "}])
      {:error, :missing_short_name}
  """
  @spec from_api_list(list()) :: {:ok, [t()]} | {:error, reason()}
  def from_api_list(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn attrs, {:ok, acc} ->
      case from_api(attrs) do
        {:ok, environment} -> {:cont, {:ok, [environment | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, environments} -> {:ok, Enum.reverse(environments)}
      {:error, reason} -> {:error, reason}
    end
  end

  def from_api_list(_other), do: {:error, :not_an_object}

  defp required_string(attrs, key, reason) do
    case blank_to_nil(Map.get(attrs, key)) do
      nil -> {:error, reason}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, reason}
    end
  end

  defp optional_string(attrs, key, reason) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, blank_to_nil(value)}
      _other -> {:error, reason}
    end
  end

  defp categories(attrs) do
    case Map.get(attrs, "categories") do
      nil ->
        {:ok, []}

      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1),
          do: {:ok, list},
          else: {:error, :invalid_categories}

      _other ->
        {:error, :invalid_categories}
    end
  end

  defp archived(attrs) do
    case Map.get(attrs, "isArchived") do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, :invalid_archived}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _trimmed -> value
    end
  end

  defp blank_to_nil(value), do: value
end
