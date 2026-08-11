defmodule Nucleus.Backend.Seed do
  @moduledoc """
  The seeded state that local backend implementations serve, held in one `Agent`.

  Nucleus has no datastore (`docs/adr/0001-no-local-datastore.md`), so a local
  implementation has nowhere to keep the data it pretends to own. This `Agent`
  is that nowhere: it parses `priv/backends/local_seed.json` once at start-up
  and holds the decoded document as its state, offering read *and* write access
  for the lifetime of the node. Restart the node and the seed is back to what is
  checked in.

  An `Agent` rather than a `GenServer` over an ETS table: an `Agent` is a
  `GenServer` specialised for exactly this — holding state on behalf of other
  processes — and a decoded JSON document is a map that needs no table.

  ## Namespaced by boundary

  The file carries one top-level key per boundary rather than a flat document,
  so the boundaries can be built and changed independently:

      {
        "tenant_api": { "environments": [...] },
        "secrets": { ... }
      }

  Each boundary reads only its own section, through `read/2`, and must ignore
  the others. A section this module knows nothing about is served back
  unchanged, so a new boundary needs no change here.

  ## Started everywhere

  This is in the supervision tree in every environment, not gated to `:dev` and
  `:test`. The local implementations ship in the release regardless — see
  `docs/adr/0002-backend-adapter-boundaries.md` on why they are not excluded
  from the build — but they are never *selected* in production, so a conditional
  child spec would buy nothing while adding a "seed owner missing" branch for
  every reader to handle.

  ## A malformed seed fails at boot

  A missing or undecodable file raises from `init`, which brings the node down.
  The file is checked in, so it cannot be valid in CI and invalid in
  production; the only way to reach this is a packaging mistake or a bad edit,
  and both should be loud. This is the single error path for the seed — no
  caller of `read/2` has to consider a parse failure.
  """

  use Agent

  @default_path "backends/local_seed.json"

  @doc """
  Starts the seed owner.

  ## Options

    * `:name` — process name, `#{inspect(__MODULE__)}` by default. Tests that
      want an isolated instance over a fixture pass their own.
    * `:path` — absolute path to the seed file. Defaults to
      `priv/#{@default_path}` inside the application directory, which resolves
      correctly from a release as well as from a checkout.

  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    path = Keyword.get(opts, :path, default_path())

    Agent.start_link(fn -> %{path: path, document: load!(path)} end, name: name)
  end

  @doc """
  The default seed file path.
  """
  @spec default_path() :: Path.t()
  def default_path, do: Application.app_dir(:nucleus, Path.join("priv", @default_path))

  @doc """
  The section of the seed belonging to `boundary`.

  Returns `nil` when the seed carries no such section, which is how a boundary
  whose implementation has landed before its seed data reads: absent, not
  broken. Callers that cannot work without their section should say so in their
  own vocabulary — a `Nucleus.Backend.Error` of kind `:not_configured` — rather
  than crashing here.
  """
  @spec read(atom(), GenServer.server()) :: term() | nil
  def read(boundary, server \\ __MODULE__) when is_atom(boundary) do
    Agent.get(server, &get_in(&1, [:document, key(boundary)]))
  end

  @doc """
  Replaces `boundary`'s section with `section`.
  """
  @spec write(atom(), term(), GenServer.server()) :: :ok
  def write(boundary, section, server \\ __MODULE__) when is_atom(boundary) do
    Agent.update(server, &put_in(&1, [:document, key(boundary)], section))
  end

  @doc """
  Replaces `boundary`'s section with `fun` applied to its current value.

  The update runs inside the `Agent`, so a read-modify-write from two processes
  cannot interleave.

      Nucleus.Backend.Seed.update(:secrets, fn secrets ->
        Map.put(secrets, "prod", %{})
      end)

  """
  @spec update(atom(), (term() -> term()), GenServer.server()) :: :ok
  def update(boundary, fun, server \\ __MODULE__)
      when is_atom(boundary) and is_function(fun, 1) do
    Agent.update(server, fn %{document: document} = state ->
      %{
        state
        | document: Map.put(document, key(boundary), fun.(Map.get(document, key(boundary))))
      }
    end)
  end

  @doc """
  Re-reads the seed file, discarding every runtime mutation.

  The seed is mutable and the owner outlives a single test, so a test that
  writes must undo it or it leaks into whatever runs next. Call this from
  `setup` rather than trying to reverse individual writes.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__) do
    Agent.update(server, fn %{path: path} = state -> %{state | document: load!(path)} end)
  end

  defp key(boundary), do: Atom.to_string(boundary)

  defp load!(path) do
    case File.read(path) do
      {:ok, contents} ->
        decode!(contents, path)

      {:error, reason} ->
        raise "cannot read backend seed at #{path}: #{:file.format_error(reason)}"
    end
  end

  defp decode!(contents, path) do
    case Jason.decode(contents) do
      {:ok, %{} = seed} ->
        seed

      {:ok, other} ->
        raise "backend seed at #{path} must be a JSON object, got: #{inspect(other)}"

      {:error, error} ->
        raise "backend seed at #{path} is not valid JSON: #{Exception.message(error)}"
    end
  end
end
