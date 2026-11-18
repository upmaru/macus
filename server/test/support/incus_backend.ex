defmodule Macus.TestSupport.IncusBackend do
  @moduledoc """
  A guest `incus.sock` fixture served by Cowboy on a Unix socket: native
  HTTP with ETags and native errors, binary uploads and chunked downloads,
  an idle stream, and WebSockets for events and operation channels. Every
  request is reported to `observer` as `{:incus, method, path, qs, headers}`.
  """

  @doc """
  Serves the fixture at `path` until the test exits. `opts` is the guest
  certificate PEM, or a keyword list of `:guest_pem`, `:extensions` (the
  discovery record's API extensions) and `:script`, a function of
  `%{method, path, qs, headers, body}` answering scripted routes (see
  `Handler`) or `nil` for the built-in ones. Returns `%{ref, connections}`;
  `open_connections/1` counts backend connections still open.
  """
  def start!(path, observer, opts \\ "") do
    opts = if is_binary(opts), do: [guest_pem: opts], else: opts
    ref = {__MODULE__, make_ref()}
    connections = :counters.new(1, [:atomics])

    state = %{
      observer: observer,
      guest_pem: Keyword.get(opts, :guest_pem, ""),
      extensions: Keyword.get(opts, :extensions, ["certificate_update", "instances"]),
      script: Keyword.get(opts, :script),
      channels: :ets.new(__MODULE__, [:set, :public])
    }

    dispatch = :cowboy_router.compile([{:_, [{:_, __MODULE__.Handler, state}]}])
    inner = path <> ".cowboy"

    {:ok, _} =
      :cowboy.start_clear(
        ref,
        %{num_acceptors: 2, socket_opts: [ip: {:local, String.to_charlist(inner)}, port: 0]},
        %{env: %{dispatch: dispatch}, idle_timeout: 60_000}
      )

    # A byte-for-byte splice in front of Cowboy counts open backend
    # connections for `open_connections/1`.
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)
    acceptor = spawn(fn -> accept(listener, inner, connections) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(acceptor, :kill)
      :cowboy.stop_listener(ref)
      File.rm(path)
      File.rm(inner)
    end)

    %{ref: ref, connections: connections}
  end

  @doc "Backend connections accepted and not yet closed."
  def open_connections(%{connections: connections}), do: :counters.get(connections, 1)

  defp accept(listener, inner, connections) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        :counters.add(connections, 1, 1)

        pid =
          spawn(fn ->
            receive do
              :go ->
                try do
                  splice(client, inner)
                after
                  :counters.sub(connections, 1, 1)
                end
            end
          end)

        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, :go)
        accept(listener, inner, connections)

      {:error, _} ->
        :ok
    end
  end

  defp splice(client, inner) do
    {:ok, server} =
      :gen_tcp.connect({:local, String.to_charlist(inner)}, 0, [:binary, active: false])

    up = spawn_link(fn -> pipe(client, server) end)
    :ok = :gen_tcp.controlling_process(client, up)
    pipe(server, client)
    ref = Process.monitor(up)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      5_000 -> Process.exit(up, :kill)
    end
  end

  # Copies bytes one way, then half-closes the other side.
  defp pipe(from, to) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        case :gen_tcp.send(to, data) do
          :ok -> pipe(from, to)
          {:error, _} -> :gen_tcp.close(from)
        end

      {:error, _} ->
        :gen_tcp.shutdown(to, :write)
    end
  end

  @doc "The deterministic export body of `chunks` 64 KiB chunks."
  def export_chunk(i), do: :binary.copy(<<rem(i, 256), 0, 255, 13, 10>>, 13_107) <> <<i::8>>

  @exec_ok "e0000000-0000-4000-8000-000000000001"
  @exec_hang "e0000000-0000-4000-8000-000000000002"

  @doc "The exec operation whose output channels finish normally."
  def exec_ok, do: @exec_ok
  @doc "The exec operation whose output channels end only after a signal."
  def exec_hang, do: @exec_hang

  defmodule Handler do
    @moduledoc false
    @exec_ok "e0000000-0000-4000-8000-000000000001"
    @exec_hang "e0000000-0000-4000-8000-000000000002"

    def init(req, state) do
      send(state.observer, {:incus, req.method, req.path, req.qs, req.headers})

      if :cowboy_req.header("upgrade", req, "") |> String.downcase() == "websocket" do
        secret = :cowboy_req.parse_qs(req) |> List.keyfind("secret", 0)

        state =
          Map.merge(state, %{path: req.path, events_qs: req.qs, secret: secret && elem(secret, 1)})

        {:cowboy_websocket, req, state, %{idle_timeout: 60_000, max_frame_size: 1_048_576}}
      else
        {:ok, route(req, state), state}
      end
    end

    defp route(req, %{script: script} = state) when is_function(script, 1) do
      {body, req} = body(req, "")

      request = %{
        method: req.method,
        path: req.path,
        qs: req.qs,
        headers: req.headers,
        body: body
      }

      send(state.observer, {:incus_request_body, req.method, req.path, body})

      case script.(request) do
        nil -> http(req.method, req.path, req, state)
        response -> scripted(response, req)
      end
    end

    defp route(req, state), do: http(req.method, req.path, req, state)

    defp body(req, acc) do
      if :cowboy_req.has_body(req) do
        case :cowboy_req.read_body(req) do
          {:ok, data, req} -> {acc <> data, req}
          {:more, data, req} -> body(req, acc <> data)
        end
      else
        {acc, req}
      end
    end

    # Scripted responses: {:sync, metadata}, {:sync, status, metadata,
    # headers}, {:async, operation}, {:error, status, message},
    # {:binary, status, headers, body}, {:stream, headers, chunks} and
    # {:sleep, ms, response}.
    defp scripted({:sync, metadata}, req), do: sync(req, 200, metadata)

    defp scripted({:sync, status, metadata, headers}, req),
      do: sync(req, status, metadata, headers)

    defp scripted({:error, status, message}, req), do: error(req, status, message)

    defp scripted({:async, operation}, req) do
      body =
        Jason.encode!(%{
          "type" => "async",
          "status" => "Operation created",
          "status_code" => 100,
          "operation" => "/1.0/operations/" <> operation["id"],
          "metadata" => operation
        })

      headers = %{
        "content-type" => "application/json",
        "location" => "/1.0/operations/" <> operation["id"]
      }

      :cowboy_req.reply(202, headers, body, req)
    end

    defp scripted({:binary, status, headers, body}, req),
      do: :cowboy_req.reply(status, headers, body, req)

    defp scripted({:stream, headers, chunks}, req) do
      req = :cowboy_req.stream_reply(200, headers, req)
      for chunk <- chunks, do: :ok = :cowboy_req.stream_body(chunk, :nofin, req)
      :ok = :cowboy_req.stream_body("", :fin, req)
      req
    end

    defp scripted({:sleep, ms, response}, req) do
      Process.sleep(ms)
      scripted(response, req)
    end

    defp http("GET", "/1.0", req, state) do
      sync(req, 200, %{
        "api_extensions" => state.extensions,
        "api_status" => "stable",
        "api_version" => "1.0",
        "auth" => "trusted",
        "public" => false,
        "auth_methods" => ["tls"],
        "config" => %{},
        "environment" => %{
          "addresses" => ["10.0.2.15:8443"],
          "certificate" => state.guest_pem,
          "server_name" => "incus-guest",
          "server_version" => "7.0"
        }
      })
    end

    defp http("GET", "/1.0/instances", req, _state),
      do: sync(req, 200, ["/1.0/instances/c1", "/1.0/instances/c2"])

    defp http("GET", "/1.0/instances/c1", req, _state),
      do: sync(req, 200, %{"name" => "c1", "status" => "Running"}, %{"etag" => ~s("etag-c1")})

    defp http("PUT", "/1.0/instances/c1", req, state) do
      {:ok, body, req} = :cowboy_req.read_body(req)
      send(state.observer, {:incus_body, body})

      if :cowboy_req.header("if-match", req) == ~s("etag-c1"),
        do: sync(req, 200, %{}),
        else: error(req, 412, "Precondition failed")
    end

    defp http("POST", "/1.0/images", req, state) do
      {size, digest, req} = digest(req, 0, :crypto.hash_init(:sha256))
      send(state.observer, {:incus_upload, size})
      sync(req, 200, %{"size" => size, "sha256" => Base.encode16(digest, case: :lower)})
    end

    defp http("GET", "/1.0/images/big/export", req, _state) do
      chunks =
        String.to_integer(:cowboy_req.parse_qs(req) |> List.keyfind("chunks", 0) |> elem(1))

      req =
        :cowboy_req.stream_reply(200, %{"content-type" => "application/octet-stream"}, req)

      for i <- 1..chunks do
        :ok = :cowboy_req.stream_body(Macus.TestSupport.IncusBackend.export_chunk(i), :nofin, req)
      end

      :ok = :cowboy_req.stream_body("", :fin, req)
      req
    end

    defp http("GET", "/1.0/instances/c1/logs/idle", req, state) do
      req = :cowboy_req.stream_reply(200, %{"content-type" => "text/plain"}, req)
      :ok = :cowboy_req.stream_body("started\n", :nofin, req)
      send(state.observer, {:incus_idle, self()})

      receive do
        :finish -> :ok
      after
        60_000 -> :ok
      end

      req
    end

    defp http(_method, _path, req, _state), do: error(req, 404, "Not found")

    defp digest(req, size, hash) do
      case :cowboy_req.read_body(req, %{length: 65_536}) do
        {:ok, data, req} ->
          {size + byte_size(data), :crypto.hash_final(:crypto.hash_update(hash, data)), req}

        {:more, data, req} ->
          digest(req, size + byte_size(data), :crypto.hash_update(hash, data))
      end
    end

    defp sync(req, status, metadata, headers \\ %{}) do
      body =
        Jason.encode!(%{
          "type" => "sync",
          "status" => "Success",
          "status_code" => status,
          "metadata" => metadata
        })

      :cowboy_req.reply(status, Map.put(headers, "content-type", "application/json"), body, req)
    end

    defp error(req, status, message) do
      body = Jason.encode!(%{"type" => "error", "error" => message, "error_code" => status})
      :cowboy_req.reply(status, %{"content-type" => "application/json"}, body, req)
    end

    # WebSockets: /1.0/events sends native events; any other path is an
    # operation channel that echoes, bursts or closes on request.
    # A subscription to the `overflow` type gets 256 events at once.
    def websocket_init(%{path: "/1.0/events"} = state) do
      count = if state.events_qs =~ "type=overflow", do: 256, else: 1

      frames =
        for i <- 1..count do
          {:text,
           Jason.encode!(%{
             "type" => "lifecycle",
             "timestamp" => "2026-11-18T00:00:00Z",
             "metadata" => %{
               "action" => "instance-started",
               "source" => "/1.0/instances/c#{i}"
             },
             "project" => "default",
             "location" => "none"
           })}
        end

      send(state.observer, {:incus_ws, self(), state.path})
      {frames, state}
    end

    # Exec channels: secrets s0 (stdin), s1 (stdout), s2 (stderr) and sc
    # (control) of operation exec_ok/0, or exec_hang/0 whose outputs end only
    # after a control signal. Console channels: c0 (echo) and cc (control).
    def websocket_init(%{path: "/1.0/operations/" <> rest, secret: secret} = state)
        when secret in ["s0", "s1", "s2", "sc", "c0", "cc"] do
      [operation, "websocket"] = String.split(rest, "/")
      :ets.insert(state.channels, {state.secret, self()})
      send(state.observer, {:incus_channel, operation, state.secret})
      state = Map.merge(state, %{operation: operation, stdin: ""})

      frames =
        case {operation, state.secret} do
          {@exec_ok, "s1"} -> [{:binary, "hello "}, {:binary, "world\n"}, {:text, ""}]
          {@exec_ok, "s2"} -> [{:binary, "warn\n"}, {:text, ""}]
          {@exec_hang, "s1"} -> [{:binary, "partial"}]
          _ -> []
        end

      {frames, state}
    end

    def websocket_init(state) do
      send(state.observer, {:incus_ws, self(), state.path})
      {[{:text, ~s({"command":"window-resize","args":{"width":"80","height":"24"}})}], state}
    end

    def websocket_handle({:binary, data}, %{secret: "s0"} = state),
      do: {[], %{state | stdin: state.stdin <> data}}

    def websocket_handle({:text, ""}, %{secret: "s0"} = state) do
      send(state.observer, {:exec_stdin, state.stdin})
      {[], state}
    end

    def websocket_handle({:text, control}, %{secret: secret} = state)
        when secret in ["sc", "cc"] do
      message = Jason.decode!(control)
      send(state.observer, {:incus_control, state.operation, message})

      if message["command"] == "signal" do
        for name <- ["s1", "s2"],
            [{_, pid}] <- [:ets.lookup(state.channels, name)],
            do: send(pid, :eof)
      end

      {[], state}
    end

    def websocket_handle({:binary, data}, %{secret: "c0"} = state),
      do: {[{:binary, data}], state}

    def websocket_handle({:text, "close-me"}, state), do: {[{:close, 4000, "bye"}], state}

    # One frame per send, so a full path suspends this process instead of
    # queueing the whole burst in its port.
    def websocket_handle({:text, "burst:" <> count}, state) do
      send(self(), {:burst, 1, String.to_integer(count)})
      {[], state}
    end

    def websocket_handle({kind, data}, state) when kind in [:text, :binary],
      do: {[{kind, data}], state}

    def websocket_handle(_frame, state), do: {[], state}

    def websocket_info({:burst, i, count}, state) when i > count do
      send(state.observer, {:incus_burst_sent, System.monotonic_time(:millisecond)})
      {[{:text, "burst-done"}], state}
    end

    def websocket_info({:burst, i, count}, state) do
      send(self(), {:burst, i + 1, count})
      {[{:binary, <<i::32, :binary.copy(<<rem(i, 256)>>, 65_532)::binary>>}], state}
    end

    def websocket_info(:eof, state), do: {[{:text, ""}], state}
    def websocket_info(_message, state), do: {[], state}

    def terminate(reason, _req, state) do
      if Map.has_key?(state, :path), do: send(state.observer, {:incus_ws_closed, reason})

      if Map.has_key?(state, :operation),
        do: send(state.observer, {:incus_channel_closed, state.operation, state.secret})

      :ok
    end
  end
end
