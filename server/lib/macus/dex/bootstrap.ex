defmodule Macus.Dex.Bootstrap do
  @moduledoc """
  Installs the configured cassettes into the operation index and tracks each
  one's readiness.

  It is a long-lived process because `Tama.Dex.import/3` with `async: true`
  replies by message: the call returns `{:ok, ref}` after its precheck and
  `{:tama_dex_import, ref, result}` arrives when the import finishes. Local
  documents are loaded in linked tasks, whose results also arrive as
  messages, so readiness queries are answered while indexing runs.

  Nothing here blocks or fails the rest of Macus. A failed or slow cassette
  is reported per cassette, with repair guidance, while committed cassettes
  keep serving. Each change emits `[:macus, :dex, :cassette]` telemetry with
  the cassette name and status, never a path or document.
  """

  use GenServer

  require Logger

  alias Macus.Dex.Config

  @event [:macus, :dex, :cassette]

  @type entry :: %{
          kind: :imported | :local,
          status: :importing | :loading | :ready | {:failed, term()},
          guidance: String.t() | nil,
          version: String.t() | nil,
          mode: :copy | :rebuild | nil,
          changed: boolean() | nil
        }

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc """
  Returns `%{status, index, cassettes, failure, guidance}`. `status` is
  `:failed` when the index could not be started, otherwise derived from the
  cassettes: `:ready` (all ready), `:starting` (some still indexing),
  `:degraded` (some failed, some ready), `:failed` (all failed) or `:empty`
  (none configured).
  """
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :failure) do
      {:ok, reason} ->
        Logger.warning("macus operation index unavailable: #{inspect(reason_kind(reason))}")
        {:ok, %{index: nil, config: nil, failure: reason, cassettes: %{}, refs: %{}}}

      :error ->
        state = %{
          index: Keyword.fetch!(opts, :index),
          config: %Config{} = Keyword.fetch!(opts, :config),
          failure: nil,
          cassettes: %{},
          refs: %{}
        }

        {:ok, state, {:continue, :install}}
    end
  end

  @impl true
  def handle_continue(:install, state) do
    state = Enum.reduce(state.config.imports, state, &start_import/2)
    state = Enum.reduce(state.config.documents, state, &start_load/2)
    {:noreply, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      status: rollup(state),
      index: state.index,
      cassettes: state.cassettes,
      failure: state.failure && reason_kind(state.failure),
      guidance: state.failure && guidance(state.failure)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:tama_dex_import, ref, result}, state) do
    case Map.pop(state.refs, ref) do
      {{:import, name}, refs} ->
        {:noreply, finish(%{state | refs: refs}, name, :imported, result)}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.refs, ref) do
      {{:load, name}, refs} ->
        Process.demonitor(ref, [:flush])
        {:noreply, finish(%{state | refs: refs}, name, :local, result)}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp start_import(%{cassette: name, unavailable: reason}, state),
    do: put_entry(state, name, :imported, {:failed, reason})

  defp start_import(spec, state) do
    name = spec.cassette

    opts =
      [sha256: spec.sha256, async: true, timeout: state.config.import_timeout] ++
        if(as = spec[:as], do: [as: as], else: [])

    case guarded(fn -> Tama.Dex.import(state.index, spec.path, opts) end) do
      {:ok, ref} when is_reference(ref) ->
        state
        |> put_in([:refs, ref], {:import, name})
        |> put_entry(name, :imported, :importing)

      {:ok, _synchronous} ->
        put_entry(state, name, :imported, {:failed, :unexpected_reply})

      {:error, reason} ->
        put_entry(state, name, :imported, {:failed, reason})
    end
  end

  defp start_load(%{cassette: name, document: source}, state) do
    index = state.index
    timeout = state.config.load_timeout

    task =
      Task.async(fn ->
        guarded(fn ->
          Tama.Dex.load(index, document(source), cassette: name, timeout: timeout)
        end)
      end)

    state
    |> put_in([:refs, task.ref], {:load, name})
    |> put_entry(name, :local, :loading)
  end

  defp document({module, function, args}), do: apply(module, function, args)
  defp document(document), do: document

  defp finish(state, name, :imported, {:ok, %{cassette: actual}}) when actual != name do
    put_entry(state, name, :imported, {:failed, {:unexpected_cassette, actual}})
  end

  defp finish(state, name, kind, {:ok, info}) do
    entry = %{
      kind: kind,
      status: :ready,
      guidance: nil,
      version: Map.get(info, :version),
      mode: Map.get(info, :mode),
      changed: Map.get(info, :changed)
    }

    emit(name, :ready)
    %{state | cassettes: Map.put(state.cassettes, name, entry)}
  end

  defp finish(state, name, kind, {:error, reason}),
    do: put_entry(state, name, kind, {:failed, reason})

  defp finish(state, name, kind, _other),
    do: put_entry(state, name, kind, {:failed, :unexpected_reply})

  defp put_entry(state, name, kind, {:failed, reason}) do
    kind_of_reason = reason_kind(reason)
    Logger.warning("macus operation index cassette #{name} failed: #{inspect(kind_of_reason)}")
    emit(name, :failed)

    entry = %{
      kind: kind,
      status: {:failed, kind_of_reason},
      guidance: guidance(reason),
      version: nil,
      mode: nil,
      changed: nil
    }

    %{state | cassettes: Map.put(state.cassettes, name, entry)}
  end

  defp put_entry(state, name, kind, status) do
    emit(name, status)
    entry = %{kind: kind, status: status, guidance: nil, version: nil, mode: nil, changed: nil}
    %{state | cassettes: Map.put(state.cassettes, name, entry)}
  end

  defp emit(name, status), do: :telemetry.execute(@event, %{}, %{cassette: name, status: status})

  defp rollup(%{failure: failure}) when not is_nil(failure), do: :failed

  defp rollup(%{cassettes: cassettes}) when map_size(cassettes) == 0, do: :empty

  defp rollup(%{cassettes: cassettes}) do
    statuses = Enum.map(cassettes, fn {_name, entry} -> entry.status end)
    failed = Enum.count(statuses, &match?({:failed, _}, &1))
    ready = Enum.count(statuses, &(&1 == :ready))

    cond do
      ready == length(statuses) -> :ready
      failed + ready < length(statuses) -> :starting
      ready > 0 -> :degraded
      true -> :failed
    end
  end

  # Runs a tama-dex call, turning a raise, throw or exit into an error so a
  # misbehaving cassette is reported instead of crashing the bootstrap.
  defp guarded(fun) do
    fun.()
  rescue
    exception -> {:error, {:exception, exception.__struct__}}
  catch
    kind, _reason -> {:error, {kind, :caught}}
  end

  # Bounded reason terms: no paths, documents or issue lists.
  defp reason_kind(reason) when is_atom(reason), do: reason
  defp reason_kind({:file, posix} = reason) when is_atom(posix), do: reason
  defp reason_kind({:index_path, why} = reason) when is_atom(why), do: reason
  defp reason_kind({:unexpected_cassette, name} = reason) when is_binary(name), do: reason
  defp reason_kind({:exception, module} = reason) when is_atom(module), do: reason
  defp reason_kind({kind, _detail}) when is_atom(kind), do: kind
  defp reason_kind({kind, _source, _detail}) when is_atom(kind), do: kind
  defp reason_kind(_reason), do: :unknown

  @reinstall "Reinstall the matching Macus package; committed cassettes keep serving."

  defp guidance(:sha256_mismatch),
    do:
      "The bundled cassette does not match the SHA-256 pin recorded at build time. " <> @reinstall

  defp guidance(:unpinned_bundle),
    do: "This build recorded no SHA-256 pin for its bundled cassette. " <> @reinstall

  defp guidance({:file, :enoent}), do: "The bundled cassette is missing. " <> @reinstall
  defp guidance({:file, _}), do: "The bundled cassette cannot be read. " <> @reinstall

  defp guidance(:cassette_conflict),
    do: "Another cassette already uses this name. Check the Macus cassette configuration."

  defp guidance(:deadline),
    do: "Indexing did not finish before its deadline. Restart the Macus server to retry."

  defp guidance({:invalid_document, _}),
    do: "The operation document is invalid. This is a Macus build defect."

  defp guidance({:duplicate_operation, _}),
    do:
      "The operation document repeats an operation ID in its cassette. This is a Macus build defect."

  defp guidance({:unexpected_cassette, actual}),
    do: "The bundled cassette is named #{actual}, not the configured name. " <> @reinstall

  defp guidance({:index_path, :enoent}),
    do: "The gateway state directory does not exist yet. Initialize it with `macus start`."

  defp guidance({:index_path, :unsafe}),
    do:
      "The gateway state directory or index file is not owner-private " <>
        "(0700 directory, 0600 file, safe ancestors). Fix its ownership and mode."

  defp guidance(reason)
       when reason in [
              :invalid_index_path,
              :invalid_owner_uid,
              :invalid_imports,
              :invalid_documents
            ] or
              (is_tuple(reason) and
                 elem(reason, 0) in [
                   :unpinned_cassette,
                   :invalid_bundle_path,
                   :invalid_cassette_name,
                   :invalid_document_source,
                   :duplicate_cassette,
                   :invalid_timeout
                 ]),
       do:
         "The operation index configuration is invalid. Every bundled cassette needs an " <>
           "absolute local path and a SHA-256 pin. This is a Macus build or configuration defect."

  defp guidance(reason)
       when is_tuple(reason) and elem(reason, 0) in [:exception, :exit, :throw, :error],
       do:
         "Indexing failed unexpectedly. Restart the Macus server; report the error if it recurs."

  defp guidance(_reason), do: "The bundled cassette is damaged or incompatible. " <> @reinstall
end
