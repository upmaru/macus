defmodule Macus.TestSupport.IncusBackend do
  @moduledoc """
  A guest `incus.sock` fixture served by Cowboy on a Unix socket: native
  HTTP with ETags and native errors, binary uploads and chunked downloads,
  an idle stream, and WebSockets for events and operation channels. Every
  request is reported to `observer` as `{:incus, method, path, qs, headers}`.
  """

  @doc "Serves the fixture at `path` until the test exits."
  def start!(path, observer, guest_pem \\ "") do
    ref = {__MODULE__, make_ref()}
    state = %{observer: observer, guest_pem: guest_pem}
    dispatch = :cowboy_router.compile([{:_, [{:_, __MODULE__.Handler, state}]}])
    inner = path <> ".cowboy"

    {:ok, _} =
      :cowboy.start_clear(
        ref,
        %{num_acceptors: 2, socket_opts: [ip: {:local, String.to_charlist(inner)}, port: 0]},
        %{env: %{dispatch: dispatch}, idle_timeout: 60_000}
      )

    # Mint, which the shared transport uses, names a Unix backend
    # `unix.socket:0`. Incus's Go server accepts that; Cowboy refuses port 0,
    # so a splice in front rewrites only that Host value.
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, String.to_charlist(path)}])

    File.chmod!(path, 0o600)
    acceptor = spawn(fn -> accept(listener, inner) end)
    :ok = :gen_tcp.controlling_process(listener, acceptor)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(acceptor, :kill)
      :cowboy.stop_listener(ref)
      File.rm(path)
      File.rm(inner)
    end)

    ref
  end

  defp accept(listener, inner) do
    case :gen_tcp.accept(listener) do
      {:ok, client} ->
        pid = spawn(fn -> receive(do: (:go -> splice(client, inner))) end)
        :ok = :gen_tcp.controlling_process(client, pid)
        send(pid, :go)
        accept(listener, inner)

      {:error, _} ->
        :ok
    end
  end

  defp splice(client, inner) do
    {:ok, server} =
      :gen_tcp.connect({:local, String.to_charlist(inner)}, 0, [:binary, active: false])

    {head, rest} = head(client, "")
    head = String.replace(head, ~r/\r\nhost: unix\.socket:0\r\n/i, "\r\nhost: unix.socket\r\n")
    :ok = :gen_tcp.send(server, [head, rest])
    up = spawn_link(fn -> pipe(client, server) end)
    :ok = :gen_tcp.controlling_process(client, up)
    pipe(server, client)
  end

  defp head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {head <> "\r\n\r\n", rest}

      [_] ->
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> head(socket, acc <> data)
          {:error, _} -> exit(:normal)
        end
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

  defmodule Handler do
    @moduledoc false

    def init(req, state) do
      send(state.observer, {:incus, req.method, req.path, req.qs, req.headers})

      if :cowboy_req.header("upgrade", req, "") |> String.downcase() == "websocket" do
        {:cowboy_websocket, req, Map.put(state, :path, req.path),
         %{idle_timeout: 60_000, max_frame_size: 1_048_576}}
      else
        {:ok, http(req.method, req.path, req, state), state}
      end
    end

    defp http("GET", "/1.0", req, state) do
      sync(req, 200, %{
        "api_extensions" => ["certificate_update", "instances"],
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

    # WebSockets: /1.0/events sends one native event; any other path is an
    # operation channel that echoes, bursts or closes on request.
    def websocket_init(%{path: "/1.0/events"} = state) do
      event =
        Jason.encode!(%{
          "type" => "lifecycle",
          "timestamp" => "2026-11-18T00:00:00Z",
          "metadata" => %{"action" => "instance-started", "source" => "/1.0/instances/c1"},
          "project" => "default",
          "location" => "none"
        })

      send(state.observer, {:incus_ws, self(), state.path})
      {[{:text, event}], state}
    end

    def websocket_init(state) do
      send(state.observer, {:incus_ws, self(), state.path})
      {[{:text, ~s({"command":"window-resize","args":{"width":"80","height":"24"}})}], state}
    end

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

    def websocket_info(_message, state), do: {[], state}

    def terminate(reason, _req, state) do
      if Map.has_key?(state, :path), do: send(state.observer, {:incus_ws_closed, reason})
      :ok
    end
  end
end
