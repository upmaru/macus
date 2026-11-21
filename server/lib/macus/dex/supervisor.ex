defmodule Macus.Dex.Supervisor do
  @moduledoc """
  Supervises the operation index and its bootstrap.

  The index file is opened only when its directory is owner-private
  (`Macus.PrivatePath.private_dir/2`) and any existing index file is an
  owner-private regular file. The directory is never created here; it
  belongs to the gateway state boundary. When the check or the
  configuration fails, only the bootstrap starts, reporting the failure
  through `Macus.Dex.readiness/1`.

  `:rest_for_one` restarts the bootstrap whenever the index restarts, so the
  configured cassettes are installed again. Repeating an unchanged import
  or load writes nothing.
  """

  use Supervisor

  alias Macus.Dex.{Bootstrap, Config}
  alias Macus.PrivatePath

  @doc false
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    index = Keyword.fetch!(opts, :index)
    bootstrap = Keyword.fetch!(opts, :bootstrap)

    children =
      with {:ok, %Config{} = config} <- Keyword.fetch!(opts, :config),
           :ok <- check_index_path(config) do
        [
          {Tama.Dex.Index, path: config.index_path, name: index},
          {Bootstrap, name: bootstrap, index: index, config: config}
        ]
      else
        {:error, reason} -> [{Bootstrap, name: bootstrap, failure: reason}]
      end

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  @spec check_index_path(Config.t()) :: :ok | {:error, {:index_path, :enoent | :unsafe}}
  def check_index_path(%Config{index_path: :memory}), do: :ok

  def check_index_path(%Config{index_path: path, owner_uid: uid}) do
    with :ok <- PrivatePath.private_dir(Path.dirname(path), uid),
         :ok <- existing_file(path, uid) do
      :ok
    else
      {:error, reason} -> {:error, {:index_path, reason}}
    end
  end

  defp existing_file(path, uid) do
    case PrivatePath.private_entry(path, uid, :regular) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end
end
