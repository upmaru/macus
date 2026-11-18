defmodule Macus.Dex.Config do
  @moduledoc """
  Validated configuration for the Macus operation index.

  - `:index_path`: the SQLite index, normally `index_path/1` for the selected
    state (`<state-dir>/server/tama-dex.sqlite3`). `:memory` is accepted for
    tests.
  - `:owner_uid`: the verified host owner. The index directory and file must
    belong to this user.
  - `:imports`: bundled cassettes, each `%{cassette: name, path: absolute
    local path, sha256: pin}` with an optional `:as`. Every import must carry
    a SHA-256 pin, so tama-dex never silently rebuilds an unpinned cassette.
    The path is a file Macus bundles at build time; nothing is downloaded.
    A bundle the build could not pin is `%{cassette: name, unavailable:
    reason}`, which installs nothing and reports that cassette as failed.
  - `:documents`: local cassettes, each `%{cassette: name, document: map |
    {module, function, args}}`.
  - `:import_timeout` and `:load_timeout`: deadlines in milliseconds.
  """

  alias Macus.Configuration

  @name ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/

  @enforce_keys [:index_path, :owner_uid]
  defstruct [
    :index_path,
    :owner_uid,
    imports: [],
    documents: [],
    import_timeout: 60_000,
    load_timeout: 15_000
  ]

  @type import_spec ::
          %{
            required(:cassette) => String.t(),
            required(:path) => String.t(),
            required(:sha256) => String.t(),
            optional(:as) => String.t()
          }
          | %{cassette: String.t(), unavailable: atom()}
  @type document_spec :: %{cassette: String.t(), document: map() | mfa()}
  @type t :: %__MODULE__{
          index_path: String.t() | :memory,
          owner_uid: non_neg_integer(),
          imports: [import_spec()],
          documents: [document_spec()],
          import_timeout: pos_integer(),
          load_timeout: pos_integer()
        }

  @doc "The index location for the selected state: `<state-dir>/server/tama-dex.sqlite3`."
  @spec index_path(Configuration.t()) :: String.t()
  def index_path(%Configuration{} = config),
    do: Path.join(Configuration.gateway_dir(config), "tama-dex.sqlite3")

  @doc "Validates options into a configuration, without touching the filesystem."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with {:ok, index_path} <- index_path_opt(Keyword.get(opts, :index_path)),
         {:ok, uid} <- uid_opt(Keyword.get(opts, :owner_uid)),
         {:ok, imports} <- imports_opt(Keyword.get(opts, :imports, [])),
         {:ok, documents} <- documents_opt(Keyword.get(opts, :documents, [])),
         :ok <- unique_names(imports, documents),
         {:ok, import_timeout} <- timeout_opt(opts, :import_timeout, 60_000),
         {:ok, load_timeout} <- timeout_opt(opts, :load_timeout, 15_000) do
      {:ok,
       %__MODULE__{
         index_path: index_path,
         owner_uid: uid,
         imports: imports,
         documents: documents,
         import_timeout: import_timeout,
         load_timeout: load_timeout
       }}
    end
  end

  defp index_path_opt(:memory), do: {:ok, :memory}

  defp index_path_opt(path) when is_binary(path) do
    if absolute?(path), do: {:ok, path}, else: {:error, :invalid_index_path}
  end

  defp index_path_opt(_), do: {:error, :invalid_index_path}

  defp uid_opt(uid) when is_integer(uid) and uid >= 0, do: {:ok, uid}
  defp uid_opt(_), do: {:error, :invalid_owner_uid}

  defp imports_opt(imports) when is_list(imports) do
    collect(imports, &import_spec/1)
  end

  defp imports_opt(_), do: {:error, :invalid_imports}

  defp import_spec(%{cassette: name, unavailable: reason} = spec)
       when map_size(spec) == 2 and is_atom(reason) do
    if name?(name),
      do: {:ok, %{cassette: name, unavailable: reason}},
      else: {:error, {:invalid_cassette_name, name}}
  end

  defp import_spec(%{cassette: name, path: path} = spec) do
    cond do
      not name?(name) ->
        {:error, {:invalid_cassette_name, name}}

      not (is_binary(path) and absolute?(path)) ->
        {:error, {:invalid_bundle_path, name}}

      not sha256?(Map.get(spec, :sha256)) ->
        {:error, {:unpinned_cassette, name}}

      Map.has_key?(spec, :as) and not name?(spec.as) ->
        {:error, {:invalid_cassette_name, spec.as}}

      true ->
        {:ok, Map.take(spec, [:cassette, :path, :sha256, :as])}
    end
  end

  defp import_spec(_), do: {:error, :invalid_imports}

  defp documents_opt(documents) when is_list(documents) do
    collect(documents, &document_spec/1)
  end

  defp documents_opt(_), do: {:error, :invalid_documents}

  defp document_spec(%{cassette: name, document: document}) do
    cond do
      not name?(name) -> {:error, {:invalid_cassette_name, name}}
      is_map(document) or mfa?(document) -> {:ok, %{cassette: name, document: document}}
      true -> {:error, {:invalid_document_source, name}}
    end
  end

  defp document_spec(_), do: {:error, :invalid_documents}

  defp unique_names(imports, documents) do
    names =
      Enum.map(imports, &Map.get(&1, :as, &1.cassette)) ++ Enum.map(documents, & &1.cassette)

    case names -- Enum.uniq(names) do
      [] -> :ok
      [name | _] -> {:error, {:duplicate_cassette, name}}
    end
  end

  defp timeout_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      timeout when is_integer(timeout) and timeout > 0 -> {:ok, timeout}
      _ -> {:error, {:invalid_timeout, key}}
    end
  end

  defp collect(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  # Absolute, local and NUL-free. A URL such as https://... is relative to
  # Path.type/1, so remote sources are rejected here.
  defp absolute?(path), do: Path.type(path) == :absolute and not String.contains?(path, <<0>>)

  defp name?(name), do: is_binary(name) and Regex.match?(@name, name)
  defp sha256?(pin), do: is_binary(pin) and Regex.match?(@sha256, pin)

  defp mfa?({module, function, args}) when is_atom(module) and is_atom(function),
    do: is_list(args)

  defp mfa?(_), do: false
end
