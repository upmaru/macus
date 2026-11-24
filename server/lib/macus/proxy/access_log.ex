defmodule Macus.Proxy.AccessLog do
  @moduledoc """
  The owner-private access log of native gateway exchanges,
  `<state-dir>/logs/gateway-access.log`.

  ## Source

  The shared library emits `[:opsmaru_incus, :gateway, :exchange, :stop]`
  once per exchange, from a per-exchange observer process, after the
  exchange has really ended. `handle_event/4` turns that event into one
  JSON line (`line/5`) and logs it under the logger domain
  `[:macus, :access]`. It rescues every error and counts it, because
  `:telemetry` detaches a handler that raises.

  ## Writer

  A dedicated `:logger_std_h` handler (`#{inspect(:macus_access)}`) accepts
  only that domain and writes the file, rotating it at #{10 * 1024 * 1024}
  bytes and keeping 5 archives (`gateway-access.log.0` newest to
  `gateway-access.log.4` oldest). A filter on the default handler drops the
  domain, so access lines never reach `server.out.log`.

  Recording never makes an exchange wait. The logger handler's synchronous
  mode is disabled, and before logging a line `handle_event/4` checks the
  handler's queue: at #{500} pending lines it drops the record instead,
  counts it and emits `[:macus, :access_log, :dropped]`. The next written
  line carries `"dropped_before": N`.

  ## Record identity

  Every record carries `"id": "BOOT-SEQ"`. `BOOT` is 64 random bits chosen
  when the log starts, as 16 lowercase hexadecimal digits, so ids from
  different server runs do not collide. `SEQ` is a decimal counter from 1,
  taken when the stop event arrives and before the drop decision, so it
  orders the records of one run and a gap marks a record that was not
  written. Concurrent exchanges can reach the file slightly out of `SEQ`
  order.

  ## Location

  `STATE/logs` must be an owner-private directory
  (`Macus.PrivatePath.private_dir/2`); it is created 0700 only when absent.
  An unsafe directory, or an existing log that is not a regular file of
  the owner, disables the access log with one error line and never stops
  the gateway: `start_link/1` returns `:ignore`. File modes come from the
  release's `umask 077` (`rel/env.sh.eex`).
  """

  use GenServer

  require Logger

  alias Macus.PrivatePath

  @event [:opsmaru_incus, :gateway, :exchange, :stop]
  @domain [:macus, :access]
  @handler :macus_access
  @default_filter :macus_access
  @telemetry_id {__MODULE__, :stop}
  @file_name "gateway-access.log"
  @max_bytes 10 * 1024 * 1024
  @max_files 5
  @drop_qlen 500
  # The logger handler's own thresholds sit above `@drop_qlen`, so the
  # telemetry handler drops (and counts) first. sync == drop disables the
  # synchronous mode, which would make the observer wait for the disk.
  @olp_qlen 1_000
  @flush_qlen 2_000

  @stats {__MODULE__, :stats}
  @errors 1
  @dropped 2
  @pending 3
  @seq 4

  @doc "The telemetry event the log records."
  def event, do: @event

  @doc "The logger domain of access lines."
  def domain, do: @domain

  @doc "The logger handler id that writes the file."
  def handler_id, do: @handler

  @doc "The log file name inside `STATE/logs`."
  def file_name, do: @file_name

  @doc "`STATE/logs` for a state directory."
  def logs_dir(state_dir) when is_binary(state_dir), do: Path.join(state_dir, "logs")

  @doc """
  Starts the access log for a prepared `Macus.Gateway`, or for
  `state_dir:` and `uid:` (tests may also pass `max_bytes:`, `max_files:`
  and `drop_qlen:`). Returns `:ignore` when the log is disabled.
  """
  def start_link(%Macus.Gateway{state: state, uid: uid}),
    do: start_link(state_dir: state.state_dir, uid: uid)

  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  @doc """
  Counts since the log started: handler errors, dropped records and
  records dropped since the last written line.
  """
  @spec stats() :: %{
          errors: non_neg_integer(),
          dropped: non_neg_integer(),
          pending: non_neg_integer()
        }
  def stats do
    case :persistent_term.get(@stats, nil) do
      nil ->
        %{errors: 0, dropped: 0, pending: 0}

      ref ->
        %{
          errors: :atomics.get(ref, @errors),
          dropped: :atomics.get(ref, @dropped),
          pending: :atomics.get(ref, @pending)
        }
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state_dir = Keyword.fetch!(opts, :state_dir)
    uid = Keyword.fetch!(opts, :uid)
    dir = logs_dir(state_dir)
    path = Path.join(dir, @file_name)

    with :ok <- prepare_dir(dir, uid),
         :ok <- existing_file(path, uid),
         :ok <- install(path, opts) do
      {:ok, %{path: path}}
    else
      {:error, reason} ->
        Logger.error("Gateway access log disabled: " <> describe(reason, dir))
        :ignore
    end
  end

  @impl true
  def terminate(_reason, _state) do
    uninstall()
  end

  defp prepare_dir(dir, uid) do
    case PrivatePath.private_dir(dir, uid) do
      :ok ->
        :ok

      {:error, :enoent} ->
        with :ok <- mkdir(dir),
             :ok <- PrivatePath.private_dir(dir, uid) do
          :ok
        else
          _ -> {:error, :unsafe_dir}
        end

      {:error, :unsafe} ->
        {:error, :unsafe_dir}
    end
  end

  defp mkdir(path) do
    case :file.make_dir(path) do
      :ok -> File.chmod(path, 0o700)
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  # The logger handler opens the file by name, following links, so an
  # existing log must be a regular file of the owner.
  defp existing_file(path, uid) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, uid: ^uid}} -> :ok
      {:error, :enoent} -> :ok
      _ -> {:error, :unsafe_file}
    end
  end

  defp install(path, opts) do
    ref = :atomics.new(4, signed: false)
    :persistent_term.put(@stats, ref)
    uninstall()

    handler = %{
      level: :all,
      filter_default: :stop,
      filters: [access: {&:logger_filters.domain/2, {:log, :equal, @domain}}],
      formatter: {__MODULE__, %{}},
      config: %{
        type: :file,
        file: String.to_charlist(path),
        max_no_bytes: Keyword.get(opts, :max_bytes, @max_bytes),
        max_no_files: Keyword.get(opts, :max_files, @max_files),
        file_check: 0,
        sync_mode_qlen: @olp_qlen,
        drop_mode_qlen: @olp_qlen,
        flush_qlen: @flush_qlen
      }
    }

    config = %{
      stats: ref,
      boot: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      handler: @handler,
      drop_qlen: Keyword.get(opts, :drop_qlen, @drop_qlen)
    }

    with :ok <- :logger.add_handler(@handler, :logger_std_h, handler) do
      # The access record is the log's purpose: the primary level does not
      # silence it. Its handler accepts nothing else.
      :ok = :logger.set_module_level(__MODULE__, :info)
      _ = :logger.add_handler_filter(:default, @default_filter, default_filter())
      :ok = :telemetry.attach(@telemetry_id, @event, &__MODULE__.handle_event/4, config)
    else
      {:error, reason} -> {:error, {:handler, reason}}
    end
  end

  @doc "The filter that keeps access lines out of the default handler."
  def default_filter, do: {&:logger_filters.domain/2, {:stop, :sub, @domain}}

  defp uninstall do
    :telemetry.detach(@telemetry_id)
    _ = :logger.remove_handler(@handler)
    _ = :logger.remove_handler_filter(:default, @default_filter)
    _ = :logger.unset_module_level(__MODULE__)
    :ok
  end

  defp describe(:unsafe_dir, dir),
    do:
      "#{dir} must be an owner-private 0700 directory below safe ancestors; the gateway serves without an access log"

  defp describe(:unsafe_file, dir),
    do:
      "#{Path.join(dir, @file_name)} must be a regular file owned by the server user; the gateway serves without an access log"

  defp describe({:handler, reason}, _dir),
    do:
      "the log handler did not start (#{inspect(reason)}); the gateway serves without an access log"

  ## Telemetry handler

  @doc """
  The `:telemetry` handler. Runs in the library's exchange observer. Never
  raises: every error is rescued and counted, so the handler stays
  attached.
  """
  def handle_event(@event, measurements, metadata, config) do
    record(measurements, metadata, config)
  rescue
    _ -> count_error(config)
  catch
    _, _ -> count_error(config)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp record(measurements, metadata, %{stats: ref, boot: boot} = config) do
    # Taken before the drop decision: a dropped record leaves a gap.
    id = boot <> "-" <> Integer.to_string(:atomics.add_get(ref, @seq, 1))

    if overloaded?(config) do
      :atomics.add(ref, @dropped, 1)
      :atomics.add(ref, @pending, 1)
      :telemetry.execute([:macus, :access_log, :dropped], %{count: 1}, %{})
    else
      dropped = :atomics.exchange(ref, @pending, 0)

      try do
        log(line(id, measurements, metadata, DateTime.utc_now(), dropped))
      rescue
        error ->
          # The marker belongs to the next line that is written.
          :atomics.add(ref, @pending, dropped)
          reraise error, __STACKTRACE__
      end
    end

    :ok
  end

  defp count_error(%{stats: ref}) do
    :atomics.add(ref, @errors, 1)
    :ok
  end

  defp count_error(_config), do: :ok

  # The handler process is registered by `logger_h_common` as
  # `logger_std_h_<id>`. A missing process means the line would be lost.
  defp overloaded?(%{handler: handler, drop_qlen: limit}) do
    case Process.whereis(:"logger_std_h_#{handler}") do
      nil ->
        true

      pid ->
        case Process.info(pid, :message_queue_len) do
          {:message_queue_len, length} -> length >= limit
          nil -> true
        end
    end
  end

  defp log(line) do
    if :logger.allow(:info, __MODULE__) do
      :logger.macro_log(
        %{mfa: {__MODULE__, :handle_event, 4}, file: ~c"#{__ENV__.file}", line: __ENV__.line},
        :info,
        line,
        %{domain: @domain}
      )
    end
  end

  ## Line

  @doc """
  The JSON line for a stop event, without the trailing newline.

  Keys, in order: `v`, `id`, `time`, `protocol`, `method`, `path`, `project`,
  `target`, `all_projects`, `operation`, `peer`, `certificate`,
  `admitted_as`, `status`, `outcome`, `reason`, `duration_ms`,
  `request_bytes`, `response_bytes`, and `dropped_before` only when
  records were dropped before this one. Unknown metadata is ignored.
  """
  @spec line(String.t(), map(), map(), DateTime.t(), non_neg_integer()) :: String.t()
  def line(id, measurements, metadata, ended_at, dropped_before \\ 0)
      when is_binary(id) and is_map(measurements) and is_map(metadata) do
    fields = [
      v: 1,
      id: id,
      time: time(ended_at),
      protocol: scalar(metadata[:protocol]),
      method: scalar(metadata[:method]),
      path: scalar(metadata[:path]),
      project: scalar(metadata[:project]),
      target: scalar(metadata[:target]),
      all_projects: metadata[:all_projects] == true,
      operation: scalar(metadata[:operation]),
      peer: peer(metadata[:peer_address], metadata[:peer_port]),
      certificate: scalar(metadata[:peer_fingerprint]),
      admitted_as: scalar(metadata[:admitted_as]),
      status: integer(metadata[:status]),
      outcome: scalar(metadata[:outcome]),
      reason: scalar(metadata[:reason]),
      duration_ms: duration(measurements[:duration]),
      request_bytes: integer(measurements[:request_bytes]),
      response_bytes: integer(measurements[:response_bytes])
    ]

    fields = if dropped_before > 0, do: fields ++ [dropped_before: dropped_before], else: fields
    Jason.encode!(Jason.OrderedObject.new(fields))
  end

  defp time(%DateTime{} = ended_at) do
    %DateTime{microsecond: {microsecond, _}} =
      ended_at = DateTime.shift_zone!(ended_at, "Etc/UTC")

    %{ended_at | microsecond: {div(microsecond, 1000) * 1000, 3}}
    |> DateTime.to_iso8601()
  end

  # Strings, numbers, booleans and nil pass; atoms become strings. Any
  # other term, or a string that is not UTF-8, is recorded as null.
  defp scalar(nil), do: nil
  defp scalar(value) when is_boolean(value), do: value
  defp scalar(value) when is_atom(value), do: Atom.to_string(value)
  defp scalar(value) when is_integer(value), do: value
  defp scalar(value) when is_binary(value), do: if(String.valid?(value), do: value)
  defp scalar(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  defp duration(nil), do: nil
  defp duration(native), do: System.convert_time_unit(native, :native, :millisecond)

  defp peer(nil, _port), do: nil

  defp peer(address, port) when is_tuple(address) do
    case :inet.ntoa(address) do
      {:error, _} -> nil
      text -> peer(List.to_string(text), port)
    end
  end

  defp peer(address, port) when is_binary(address) do
    cond do
      not String.valid?(address) -> nil
      not is_integer(port) -> address
      String.contains?(address, ":") -> "[#{address}]:#{port}"
      true -> "#{address}:#{port}"
    end
  end

  defp peer(_address, _port), do: nil

  ## Logger formatter

  @doc false
  def check_config(_config), do: :ok

  @doc false
  # Access lines are logged as strings. The handler's own notices
  # (such as a flush report) are not records and are not written.
  def format(%{msg: {:string, line}, meta: %{domain: @domain}}, _config), do: [line, ?\n]
  def format(_event, _config), do: []
end
