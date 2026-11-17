defmodule Macus.Dex do
  @moduledoc """
  The Macus operation index (tama-dex) behind the `/mcp` `search` and
  `execute` tools.

  One `Tama.Dex.Index` at `<state-dir>/server/tama-dex.sqlite3` holds the
  imported `opsmaru_incus` cassette, bundled with a SHA-256 pin, and the
  local `macus` cassette. `Macus.Dex.Bootstrap` installs them when the
  subtree starts and tracks each cassette's readiness. That readiness is
  gateway readiness, separate from VM readiness.

  The subtree is a temporary child, so an index failure can never stop the
  Macus server or affect the VM. It starts only when `Macus.Dex` is enabled
  in the application environment; otherwise nothing is opened or created.
  """

  alias Macus.Dex.{Bootstrap, Config}

  @index Macus.Dex.Index
  @bootstrap Macus.Dex.Bootstrap

  @doc """
  A temporary child specification for the index subtree.

  Takes `:config` (`{:ok, %Macus.Dex.Config{}}` or `{:error, reason}`, as
  returned by `Macus.Dex.Config.new/1`) and optional `:index`,
  `:bootstrap` and `:name` registration names.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts =
      opts
      |> Keyword.put_new(:index, @index)
      |> Keyword.put_new(:bootstrap, @bootstrap)
      |> Keyword.put_new(:name, Macus.Dex.Supervisor)

    %{
      id: Keyword.fetch!(opts, :name),
      start: {Macus.Dex.Supervisor, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @doc """
  Builds the child specifications from the `:macus, Macus.Dex` application
  environment. Returns `[]` unless `enabled: true`, so a default start opens
  and creates nothing.

  The index path is derived from the selected state directory. `:owner_uid`,
  `:imports` and `:documents` come from the environment; see
  `Macus.Dex.Config`. `:documents` defaults to `runtime_document/0`.
  """
  @spec children(keyword(), Macus.Configuration.t() | nil) :: [Supervisor.child_spec()]
  def children(env, state) do
    if Keyword.get(env, :enabled, false) do
      config =
        case state do
          %Macus.Configuration{} ->
            env
            |> Keyword.drop([:enabled])
            |> Keyword.put(:index_path, Config.index_path(state))
            |> Keyword.put_new(:documents, [runtime_document()])
            |> Config.new()

          nil ->
            {:error, :invalid_index_path}
        end

      [child_spec(config: config)]
    else
      []
    end
  end

  @doc "The local `macus` cassette: the Macus runtime operations document."
  @spec runtime_document() :: Config.document_spec()
  def runtime_document,
    do: %{cassette: "macus", document: {Macus.Dex.RuntimeDocument, :document, []}}

  @doc "The registered index, for `Tama.Dex` calls."
  @spec index() :: atom()
  def index, do: @index

  @doc """
  Gateway readiness of the operation index: the bootstrap's snapshot plus,
  per cassette, `serving_version` when a committed version is still serving
  (for example the previous version after a rejected upgrade). Returns
  `%{status: :unavailable}` when the subtree is not running.
  """
  @spec readiness(GenServer.server()) :: map()
  def readiness(bootstrap \\ @bootstrap) do
    snapshot = Bootstrap.snapshot(bootstrap)
    Map.update!(snapshot, :cassettes, &with_serving(&1, snapshot.index))
  catch
    :exit, _reason ->
      %{status: :unavailable, index: nil, cassettes: %{}, failure: nil, guidance: nil}
  end

  defp with_serving(cassettes, nil), do: cassettes

  defp with_serving(cassettes, index) do
    committed =
      try do
        for %{cassette: name, status: :ready, version: version} <- Tama.Dex.cassettes(index),
            into: %{},
            do: {name, version}
      catch
        :exit, _reason -> %{}
      end

    Map.new(cassettes, fn {name, entry} ->
      {name, Map.put(entry, :serving_version, Map.get(committed, name))}
    end)
  end
end
