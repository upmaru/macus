defmodule Macus.Proxy.NativeRelayTest do
  # Section 5 against Macus.Gateway's own TLS listener: the shared gateway's
  # HTTP, WebSocket and raw relays mounted with Macus host policy over a
  # fixture guest incus.sock. The listener name, admission and trust are
  # global.
  use ExUnit.Case, async: false

  alias Macus.Proxy.Trust

  alias Macus.TestSupport.{
    AccessLogAudit,
    AuthFixtures,
    DexFixtures,
    IncusBackend,
    NativeBackend,
    TLSIdentity
  }

  alias Opsmaru.Incus.Gateway.Admission

  @driver Path.expand("../../../../.integration/incus-reference-driver", __DIR__)
  @reference_dir Path.expand("../../reference", __DIR__)
  @admission Macus.Proxy.Admission
  @revision String.duplicate("ab12", 10)
  # A tightened revocation bound keeps the revocation tests short. Only those
  # tests set it: the shared gateway rechecks every live exchange within the
  # bound and gives the host callback a quarter of it, and a callback that
  # overruns revokes the exchange (fail closed). At 400 ms that budget is
  # 100 ms, which a loaded CI runner's trust-file read exceeds, ending
  # streams that no test meant to revoke. Every other test keeps the
  # production bound and its 1 s callback budget.
  @bound 1_000
  @mcp_version "2026-07-28"
  # A receive timeout: Mint.WebSocket.recv/3 returns the raw :ssl reason after
  # the upgrade, Mint.HTTP.recv/3 this struct before it.
  @timeout %Mint.TransportError{reason: :timeout}

  setup_all do
    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: @reference_dir,
        stderr_to_stdout: true,
        env: [{"GOTOOLCHAIN", "local"}]
      )

    assert status == 0, output
    :ok
  end

  setup do
    root = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {state_dir, uid} = AuthFixtures.state!(root)
    AuthFixtures.configure!(state_dir, uid)
    {:ok, state} = Macus.Configuration.new(state_dir)
    certs = Path.join(root, "certs")
    File.mkdir!(certs)
    File.chmod!(certs, 0o700)
    admin = TLSIdentity.self_signed(certs, "admin")
    guest = TLSIdentity.self_signed(certs, "guest", "incus-guest")

    build = Application.fetch_env(:macus, Macus.Build)
    proxy = Application.fetch_env(:macus, Macus.Proxy)
    Application.put_env(:macus, Macus.Build, revision: @revision)

    Application.put_env(:macus, Macus.Proxy,
      api_extensions: ["certificate_update", "instances", "instance_nbd"]
    )

    on_exit(fn ->
      restore(Macus.Build, build)
      restore(Macus.Proxy, proxy)
    end)

    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    path = Path.join(Macus.Configuration.gateway_dir(state), "gateway.json")
    File.write!(path, Jason.encode!(%{"schema_version" => 1, "port" => port}))
    File.chmod!(path, 0o600)

    {:ok, gateway} =
      Macus.Gateway.prepare(
        state: state,
        uid: uid,
        expected_revision: @revision,
        now: DateTime.utc_now()
      )

    # Every test here also writes the access log, and whatever it wrote is
    # held to the redaction rule once the test's processes have stopped.
    start_supervised!({Macus.Proxy.AccessLog, [state_dir: state_dir, uid: uid]})
    access_log = Path.join(Macus.Proxy.AccessLog.logs_dir(state_dir), "gateway-access.log")

    on_exit(fn ->
      written = if File.exists?(access_log), do: File.read!(access_log), else: ""
      assert AccessLogAudit.violations(written, [Base.encode64(admin.der, padding: false)]) == []
    end)

    start_supervised!(Macus.Gateway.listener(gateway))
    start_supervised!({Macus.Gateway.Publisher, gateway})
    trust!(state, [admin])

    %{
      root: root,
      state: state,
      state_dir: state_dir,
      admin: admin,
      guest: guest,
      gateway: gateway,
      port: port,
      sock: Path.join(state_dir, "incus.sock"),
      baseline: Admission.count(@admission)
    }
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:macus, key, value)
  defp restore(key, :error), do: Application.delete_env(:macus, key)

  describe "native HTTP (5.1)" do
    test "queries, conditions, statuses and native errors pass; hop-by-hop fields do not",
         context do
      IncusBackend.start!(context.sock, self(), context.guest.pem)
      socket = tls!(context)
      target = "/1.0/instances/c1?project=one+two&target=node%2Fa"

      :ok =
        :ssl.send(socket, [
          "GET #{target} HTTP/1.1\r\nhost: 127.0.0.1\r\n",
          "connection: close, x-hop\r\nx-hop: secret\r\nkeep-alive: timeout=5\r\n",
          "te: trailers\r\nproxy-authorization: Basic c2VjcmV0\r\n",
          "x-native: kept\r\nif-none-match: \"old\"\r\n\r\n"
        ])

      response = read(socket)
      assert response =~ ~r/\AHTTP\/1.1 200/
      assert response =~ ~r/\r\netag: "etag-c1"\r\n/i
      assert_receive {:incus, "GET", "/1.0/instances/c1", "project=one+two&target=node%2Fa", seen}

      for name <- ["x-hop", "keep-alive", "te", "proxy-authorization"],
          do: refute(Map.has_key?(seen, name), name)

      assert seen["x-native"] == "kept"
      assert seen["if-none-match"] == ~s("old")

      # The official client's ETag round trip and native error statuses.
      fetched = driver!(context, %{"method" => "GET", "path" => "/1.0/instances/c1"})
      assert fetched["etag"] == ~s("etag-c1")
      assert fetched["response"]["metadata"]["name"] == "c1"

      put = %{"method" => "PUT", "path" => "/1.0/instances/c1", "body" => %{"description" => "x"}}
      refute driver!(context, Map.put(put, "etag", ~s("etag-c1")))["error"]
      assert_receive {:incus_body, body}
      assert Jason.decode!(body) == %{"description" => "x"}

      stale = driver!(context, Map.put(put, "etag", ~s("stale")))
      assert stale["error_status"] == 412
      assert stale["error"] =~ "Precondition failed"

      missing = driver!(context, %{"method" => "GET", "path" => "/1.0/instances/missing"})
      assert missing["error_status"] == 404
      assert missing["error"] =~ "Not found"
    end

    test "binary uploads and chunked downloads larger than buffered limits stream through",
         context do
      IncusBackend.start!(context.sock, self(), context.guest.pem)

      # 12 MiB: beyond the 8 MiB buffered response and 1 MiB control body
      # limits, so only the streaming relay can carry it.
      upload = :crypto.strong_rand_bytes(12 * 1_048_576)

      {200, _, body} =
        http!(
          context,
          "POST",
          "/1.0/images",
          [{"content-type", "application/octet-stream"}],
          upload
        )

      metadata = Jason.decode!(body)["metadata"]
      assert metadata["size"] == byte_size(upload)
      assert metadata["sha256"] == Base.encode16(:crypto.hash(:sha256, upload), case: :lower)

      chunks = 192
      {200, headers, export} = http!(context, "GET", "/1.0/images/big/export?chunks=#{chunks}")
      assert {"content-type", "application/octet-stream"} in headers
      expected = for i <- 1..chunks, into: "", do: IncusBackend.export_chunk(i)
      assert byte_size(export) == byte_size(expected)
      assert export == expected
      wait_for_count(context.baseline)
    end

    test "an image-copy server peer without a certificate reaches only its secret's routes",
         context do
      fp = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      other = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      wait = "0b1c2d3e-0000-4000-8000-0000000000ee"
      # Secrets in incusd's format: 32 random bytes in lowercase hex.
      [secret, wait_secret, wrong] =
        for _ <- 1..3, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      # A gzip-framed image, as real image files are. Wholly random bytes
      # would start with `{` or JSON whitespace about one time in 51, which
      # the gateway rightly refuses as a JSON image request.
      image = <<0x1F, 0x8B, 0x08, 0x00>> <> :crypto.strong_rand_bytes(256 * 1024)
      wait_path = "/1.0/operations/#{wait}/wait"
      export_path = "/1.0/images/#{fp}/export"

      # The guest's pending image token, which an authorized caller created
      # through the gateway, and the operation a push waits on.
      IncusBackend.start!(context.sock, self(),
        guest_pem: context.guest.pem,
        script: fn
          %{method: "GET", path: "/1.0/operations"} ->
            {:sync,
             %{
               "running" => [
                 %{
                   "id" => "token",
                   "class" => "token",
                   "resources" => %{"images" => ["/1.0/images/#{fp}"]},
                   "metadata" => %{"secret" => secret}
                 }
               ]
             }}

          %{method: "GET", path: "/1.0/operations/" <> ^wait} ->
            {:sync, %{"id" => wait, "class" => "task", "metadata" => %{"secret" => wait_secret}}}

          %{method: "GET", path: ^wait_path} ->
            {:sync, %{"id" => wait, "status" => "Success"}}

          %{method: "GET", path: "/1.0/images/" <> ^fp} ->
            {:sync, %{"fingerprint" => fp, "public" => false}}

          %{method: "GET", path: ^export_path} ->
            {:binary, 200, %{"content-type" => "application/octet-stream"}, image}

          %{method: "POST", path: "/1.0/images", body: body} ->
            {:sync, %{"size" => byte_size(body)}}

          _ ->
            nil
        end
      )

      push = fn secret, fingerprint, body ->
        http_as!(
          context,
          nil,
          "POST",
          "/1.0/images",
          [
            {"content-type", "application/octet-stream"},
            {"x-incus-secret", secret},
            {"x-incus-fingerprint", fingerprint}
          ],
          body
        )
      end

      # Pull: the other server reads and exports the image with the secret.
      {200, _, info} = http_as!(context, nil, "GET", "/1.0/images/#{fp}?secret=#{secret}")
      # Admission reads the guest's pending operations once.
      assert_receive {:incus, "GET", "/1.0/operations", "recursion=1&project=default", _}
      assert Jason.decode!(info)["metadata"]["fingerprint"] == fp
      query = "secret=#{secret}"
      assert_receive {:incus, "GET", "/1.0/images/" <> ^fp, ^query, _}

      {200, _, ^image} =
        http_as!(context, nil, "GET", "/1.0/images/#{fp}/export?secret=#{secret}")

      assert_receive {:incus, "GET", ^export_path, ^query, _}

      # Push: it uploads the image itself, then waits on the operation.
      {200, _, uploaded} = push.(secret, fp, image)
      assert Jason.decode!(uploaded)["metadata"]["size"] == byte_size(image)
      assert_receive {:incus, "POST", "/1.0/images", "", %{"x-incus-secret" => ^secret}}
      assert_receive {:incus_request_body, "POST", "/1.0/images", ^image}

      {200, _, _} =
        http_as!(context, nil, "GET", "/1.0/operations/#{wait}/wait?secret=#{wait_secret}")

      wait_query = "secret=#{wait_secret}"
      assert_receive {:incus, "GET", ^wait_path, ^wait_query, _}

      wait_for_count(context.baseline)

      # A JSON image request in place of the image is refused before it
      # reaches the guest, which would otherwise consume the secret.
      {403, _, _} = push.(secret, fp, ~s({"source":{"type":"url","url":"https://example.net"}}))
      refute_received {:incus, "POST", "/1.0/images", _, _}

      # Wrong secrets, another image's fingerprint, a wait on an operation
      # whose secret differs and a secret-less request never reach the
      # image routes.
      for {method, path} <- [
            {"GET", "/1.0/images/#{fp}?secret=#{wrong}"},
            {"GET", "/1.0/images/#{fp}/export?secret=#{wrong}"},
            {"GET", "/1.0/images/#{other}?secret=#{secret}"},
            {"GET", "/1.0/operations/#{wait}/wait?secret=#{secret}"},
            {"GET", "/1.0/images/#{fp}"}
          ] do
        {403, _, _} = http_as!(context, nil, method, path)
      end

      {403, _, _} = push.(wrong, fp, image)
      {403, _, _} = push.(secret, other, image)

      refute_received {:incus, "GET", "/1.0/images/" <> _, _, _}
      refute_received {:incus, "GET", ^wait_path, _, _}
      refute_received {:incus, "POST", "/1.0/images", _, _}
      wait_for_count(context.baseline)
    end
  end

  describe "WebSockets (5.2)" do
    test "operation channels relay native control and data frames and close natively",
         context do
      IncusBackend.start!(context.sock, self(), context.guest.pem)
      ws = ws!(context, "/1.0/operations/op1/websocket?secret=s3")
      assert_receive {:incus, "GET", "/1.0/operations/op1/websocket", "secret=s3", _}
      {ws, [{:text, control}]} = frames(ws, 1)
      assert Jason.decode!(control)["command"] == "window-resize"

      binary = :crypto.strong_rand_bytes(200_000)
      ws = send_frame(ws, {:binary, binary})
      {ws, [{:binary, ^binary}]} = frames(ws, 1)
      ws = send_frame(ws, {:text, ~s({"command":"signal","signal":2})})
      {ws, [{:text, ~s({"command":"signal","signal":2})}]} = frames(ws, 1)

      # Ping/pong is negotiated locally on each side.
      ws = send_frame(ws, {:ping, "local"})
      {ws, [{:pong, "local"}]} = frames(ws, 1)

      # A backend close keeps its code and reason.
      ws = send_frame(ws, {:text, "close-me"})
      {_ws, [{:close, 4000, "bye"}]} = frames(ws, 1)
      wait_for_count(context.baseline)

      # A client close reaches the backend as a native close.
      ws = ws!(context, "/1.0/operations/op2/websocket?secret=s4")
      {ws, [{:text, _}]} = frames(ws, 1)
      _ws = send_frame(ws, {:close, 1000, ""})
      assert_receive {:incus_ws_closed, {:remote, 1000, ""}}, 2_000
      wait_for_count(context.baseline)
    end

    test "a server peer without a certificate reaches only a running migration's channel",
         context do
      migration = "a0000000-0000-4000-8000-0000000000aa"
      exec = "a0000000-0000-4000-8000-0000000000bb"
      # Secrets in incusd's format: 32 random bytes in lowercase hex.
      [control, fs, stdin, exec_control, wrong] =
        for _ <- 1..5, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      operations = %{
        migration => %{"control" => control, "fs" => fs},
        exec => %{"fds" => %{"0" => stdin, "control" => exec_control}}
      }

      IncusBackend.start!(context.sock, self(),
        guest_pem: context.guest.pem,
        script: fn
          %{method: "GET", path: "/1.0/operations/" <> id} when is_map_key(operations, id) ->
            {:sync,
             %{
               "id" => id,
               "class" => "websocket",
               "status" => "Running",
               "resources" => %{"instances" => ["/1.0/instances/source"]},
               "metadata" => operations[id]
             }}

          _ ->
            nil
        end
      )

      # The pinned migration dialer presents no client certificate; the
      # channel is admitted from the guest's running migration and relayed.
      {:ok, ws} = ws(context, "/1.0/operations/#{migration}/websocket?secret=#{control}", nil)
      assert_receive {:incus, "GET", "/1.0/operations/" <> ^migration, "project=default", _}
      query = "secret=#{control}"
      assert_receive {:incus, "GET", path, ^query, _}
      assert path == "/1.0/operations/#{migration}/websocket"
      {ws, [{:text, _}]} = frames(ws, 1)
      _ws = send_frame(ws, {:close, 1000, ""})
      assert_receive {:incus_ws_closed, {:remote, 1000, ""}}, 2_000
      wait_for_count(context.baseline)

      # A wrong secret, an exec session's secret or an unknown operation is
      # refused before the channel reaches the guest.
      unknown = "a0000000-0000-4000-8000-0000000000cc"

      for {id, secret} <- [
            {migration, wrong},
            {exec, stdin},
            {exec, exec_control},
            {unknown, control},
            {migration, "s3"}
          ] do
        assert {:refused, 403} =
                 ws(context, "/1.0/operations/#{id}/websocket?secret=#{secret}", nil)

        refute_received {:incus, "GET", "/1.0/operations/" <> _, "secret=" <> _, _}
      end

      wait_for_count(context.baseline)
    end

    test "a server peer copying a custom volume reaches only that migration's channel",
         context do
      volume = "a0000000-0000-4000-8000-0000000000dd"

      [control, fs, wrong] =
        for _ <- 1..3, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      # A custom volume migration in a nondefault project, as incusd renders
      # it for `incus storage volume copy` in pull or push mode.
      IncusBackend.start!(context.sock, self(),
        guest_pem: context.guest.pem,
        script: fn
          %{method: "GET", path: "/1.0/operations/" <> ^volume} ->
            {:sync,
             %{
               "id" => volume,
               "class" => "websocket",
               "status" => "Running",
               "resources" => %{
                 "storage_volumes" => [
                   "/1.0/storage-pools/default/volumes/custom/data?project=work"
                 ]
               },
               "metadata" => %{"control" => control, "fs" => fs}
             }}

          _ ->
            nil
        end
      )

      # The other server dials the control and filesystem channels with no
      # certificate, with or without the operation's project.
      channel = "/1.0/operations/#{volume}/websocket"

      for {query, project} <- [
            {"secret=#{control}", "project=default"},
            {"project=work&secret=#{fs}", "project=work"}
          ] do
        {:ok, ws} = ws(context, "#{channel}?#{query}", nil)
        assert_receive {:incus, "GET", "/1.0/operations/" <> ^volume, ^project, _}
        assert_receive {:incus, "GET", ^channel, ^query, _}
        assert_receive {:incus_ws, _, ^channel}
        {ws, [{:text, _}]} = frames(ws, 1)
        _ws = send_frame(ws, {:close, 1000, ""})
        assert_receive {:incus_ws_closed, {:remote, 1000, ""}}, 2_000
        wait_for_count(context.baseline)
      end

      # A wrong secret or another project's selection never reaches the
      # channel.
      for query <- ["secret=#{wrong}", "project=default&secret=#{control}"] do
        assert {:refused, 403} = ws(context, "#{channel}?#{query}", nil)
        refute_received {:incus, "GET", ^channel, _, _}
      end

      wait_for_count(context.baseline)
    end

    test "a paused reader holds the backend back instead of buffering the burst", context do
      IncusBackend.start!(context.sock, self(), context.guest.pem)
      ws = ws!(context, "/1.0/operations/op1/websocket?secret=s3")
      {ws, [{:text, _}]} = frames(ws, 1)

      # 32 MiB in 64 KiB frames while this reader does not read: far more
      # than the socket buffers on the path (about 8 MiB of TCP auto-tuning).
      count = 512
      ws = send_frame(ws, {:text, "burst:#{count}"})
      Process.sleep(500)
      refute_received {:incus_burst_sent, _}
      resumed = System.monotonic_time(:millisecond)
      {_ws, received} = frames(ws, count + 1, 15_000)
      assert List.last(received) == {:text, "burst-done"}

      for {{:binary, <<i::32, rest::binary>>}, expected} <- Enum.zip(received, 1..count) do
        assert i == expected
        assert rest == :binary.copy(<<rem(expected, 256)>>, 65_532)
      end

      assert_receive {:incus_burst_sent, sent}, 2_000
      assert sent >= resumed
    end

    test "untrusted upgrades never reach the backend; revocation closes open ones in bound",
         context do
      put_proxy(recheck_interval: @bound)
      IncusBackend.start!(context.sock, self(), context.guest.pem)
      assert {:refused, 403} = ws(context, "/1.0/events", nil)
      refute_receive {:incus, _, _, _, _}, 100

      ws = ws!(context, "/1.0/events")
      {ws, [{:text, _}]} = frames(ws, 1)
      trust!(context.state, [])
      started = System.monotonic_time(:millisecond)
      assert {_ws, :closed} = until_closed(ws, @bound + 2_000)
      assert System.monotonic_time(:millisecond) - started <= @bound + 300
      assert_receive {:incus_ws_closed, _}, 1_000
      wait_for_count(context.baseline)
    end
  end

  describe "admission and stream budgets (5.3)" do
    test "saturated native streams leave runtime and MCP answering and return their slots",
         context do
      IncusBackend.start!(context.sock, self(), context.guest.pem)
      {token, record} = AuthFixtures.token!(["runtime.read", "incus.read"])
      AuthFixtures.store!(context.state_dir, [record])

      # Fill all but one slot, then hold the last with an idle native stream.
      holders = fill_admission(Admission.count(@admission) + 1)
      on_exit(fn -> Enum.each(holders, &Process.exit(&1, :kill)) end)
      stream = tls!(context)
      :ok = :ssl.send(stream, request("GET", "/1.0/instances/c1/logs/idle"))
      assert_receive {:incus_idle, _}, 2_000
      assert receive_until(stream, "started\n") =~ ~r/\AHTTP\/1.1 200/

      refused = tls!(context)
      :ok = :ssl.send(refused, request("GET", "/1.0/instances/c1"))
      response = read(refused)
      assert response =~ ~r/\AHTTP\/1.1 503/
      assert response =~ "Gateway is at capacity"
      refute_receive {:incus, "GET", "/1.0/instances/c1", _, _}, 100

      # Bearer authentication, runtime status/health and MCP still answer.
      for path <- ["/runtime/status", "/runtime/health"] do
        runtime = tls!(context, nil)
        :ok = :ssl.send(runtime, request("GET", path, [{"authorization", "Bearer " <> token}]))
        response = read(runtime)
        assert response =~ ~r/\AHTTP\/1.1 503/, path
        assert response =~ ~s("outcome":"not_dispatched")
      end

      mcp = tls!(context, nil)
      body = mcp_list_tools()
      :ok = :ssl.send(mcp, request("POST", "/mcp", mcp_headers(token), body))
      response = read(mcp)
      assert response =~ ~r/\AHTTP\/1.1 200/
      assert response =~ ~s("search")

      # A client that disconnects mid-stream returns its slot.
      full = Admission.count(@admission)
      :ok = :ssl.close(stream)
      wait_for_count(full - 1)
      ok = tls!(context)
      :ok = :ssl.send(ok, request("GET", "/1.0/instances/c1"))
      assert read(ok) =~ ~r/\AHTTP\/1.1 200/
      Enum.each(holders, &Process.exit(&1, :kill))
      wait_for_count(context.baseline)

      # A failed backend connection returns its slot too.
      File.rm!(context.sock)
      failed = tls!(context)
      :ok = :ssl.send(failed, request("GET", "/1.0/instances/c1"))
      assert read(failed) =~ ~r/\AHTTP\/1.1 50[23]/
      wait_for_count(context.baseline)
    end

    test "idle and over-long native streams end and return their slots", context do
      IncusBackend.start!(context.sock, self(), context.guest.pem)
      put_proxy(idle_timeout: 300)
      stream = tls!(context)
      :ok = :ssl.send(stream, request("GET", "/1.0/instances/c1/logs/idle"))
      assert_receive {:incus_idle, _}, 2_000
      started = System.monotonic_time(:millisecond)
      assert drain_until_closed(stream, started + 3_000) == :closed
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed < 2_500, "idle stream ended after #{elapsed} ms"
      wait_for_count(context.baseline)

      # A WebSocket that keeps moving still ends at its lifetime budget. The
      # budget runs from the upgrade, so time from before the handshake: the
      # stream cannot end sooner, however slowly the handshake completes.
      put_proxy(idle_timeout: 60_000, max_lifetime: 600)
      started = System.monotonic_time(:millisecond)
      ws = ws!(context, "/1.0/operations/op1/websocket?secret=s3")
      {ws, [{:text, _}]} = frames(ws, 1)
      assert {:closed, how} = keep_talking(ws, started + 3_000)
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed >= 600 and elapsed < 2_500,
             "lifetime ended after #{elapsed} ms: #{inspect(how)}"

      wait_for_count(context.baseline)
    end
  end

  describe "raw upgrades on the production listener (5.4)" do
    for protocol <- ["sftp", "nbd"] do
      @tag protocol: protocol
      test "the official client negotiates #{protocol} and the tunnel cleans up", context do
        initial = <<0, 255, 128, 13, 10>>
        backend = native!(context, initial: initial)
        payload = :binary.copy(<<128, 0, 255, 3>>, 65_536)

        result =
          driver!(context, %{
            "protocol" => context.protocol,
            "payload" => Base.encode64(payload),
            "read_initial" => byte_size(initial)
          })

        assert Base.decode64!(result["initial"]) == initial
        assert Base.decode64!(result["echo"]) == payload
        assert_receive {:backend_request, head}
        assert head =~ "GET /1.0/instances/fixture/#{context.protocol} HTTP/1.1"
        assert_receive {:backend_closed, _}, 2_000
        # The client's discovery request, then the upgrade.
        assert NativeBackend.accepted(backend) == 2
        wait_for_count(context.baseline)
      end
    end

    @tag protocol: "nbd"
    test "coalesced bytes, half-close and auth before backend connect", context do
      initial = :binary.copy(<<0, 255, 128, 13, 10, 0, 1>>, 2_000)
      backend = native!(context, initial: initial)

      # Anonymous: refused with no backend connection.
      anonymous = tls!(context, nil)
      :ok = :ssl.send(anonymous, upgrade("/1.0/instances/fixture/nbd", "nbd"))
      assert read(anonymous) =~ ~r/\AHTTP\/1.1 403/
      assert NativeBackend.accepted(backend) == 0

      # Bytes sent with the handshake arrive; a large transfer streams.
      socket = tls!(context)
      early = <<255, 0, 128, 1>>
      target = "/1.0/instances/fixture/nbd?project=one+two&target=node%2Fa"
      :ok = :ssl.send(socket, [upgrade(target, "nbd"), early])
      {head, buffered} = read_head(socket)
      assert head =~ "HTTP/1.1 101 "
      assert receive_exact(socket, buffered, byte_size(initial <> early)) == initial <> early
      assert_receive {:backend_request, request}
      assert request =~ "GET #{target} HTTP/1.1"
      payload = :binary.copy(<<0, 255, 2, 128>>, 131_072)
      :ok = :ssl.send(socket, payload)
      assert receive_exact(socket, "", byte_size(payload)) == payload
      :ok = :ssl.close(socket)
      assert_receive {:backend_closed, _}, 2_000
      wait_for_count(context.baseline)
    end

    @tag protocol: "nbd"
    test "a backend half-close keeps the client-to-backend direction", context do
      initial = <<0, 1, 255>>
      native!(context, initial: initial, half_close: true)
      remaining = <<255, 128, 0, 7>>

      result =
        driver!(context, %{
          "protocol" => "nbd",
          "payload" => Base.encode64(remaining),
          "read_initial" => byte_size(initial),
          "half_close" => true
        })

      assert Base.decode64!(result["initial"]) == initial
      assert result["read_eof"]
      assert_receive {:backend_bytes, ^remaining}, 1_000
    end

    # TLS close_notify from the client ends both directions at the gateway
    # (OTP :ssl, erlang/otp#12296). The same client and backend over the
    # Unix socket alone show that the reply is the gateway's to lose.
    @tag protocol: "nbd"
    test "a client close_notify delivers what preceded it and loses the reply", context do
      native!(context, session: reply_after_eof(self()))
      payload = :binary.copy(<<0, 255, 2, 128>>, 1_048_576)

      fields = %{
        "protocol" => "nbd",
        "payload" => Base.encode64(payload),
        "close_write" => true
      }

      direct = driver!(context, Map.put(fields, "socket", context.sock))
      assert_receive {:backend_eof, received}, 2_000
      assert received == byte_size(payload)
      assert_receive {:backend_reply, :ok}
      assert Base.decode64!(direct["reply"]) == "after-eof"

      result = driver!(context, fields)
      assert_receive {:backend_eof, ^received}, 2_000
      assert_receive {:backend_reply, _}
      assert result["reply"] in [nil, ""]
      wait_for_count(context.baseline)
    end

    @tag protocol: "nbd"
    test "after a backend half-close the client can still send and finish", context do
      native!(context, half_close: true, session: drain(self()))
      payload = :binary.copy(<<0, 255, 2, 128>>, 1_048_576)

      driver!(context, %{
        "protocol" => "nbd",
        "payload" => Base.encode64(payload),
        "half_close" => true,
        "close_write" => true
      })

      assert_receive {:backend_drained, received, _elapsed}, 2_000
      assert received == byte_size(payload)
      wait_for_count(context.baseline)
    end

    # The drain window is the connection's 5 s timeout, counted from the first
    # EOF; traffic in the open direction does not extend it.
    @tag protocol: "nbd"
    test "a backend half-close leaves the client direction open for only 5 s", context do
      native!(context, half_close: true, session: drain(self()))

      driver!(context, %{
        "protocol" => "nbd",
        "payload" => Base.encode64("x"),
        "half_close" => true,
        "repeat" => 16,
        "interval_ms" => 500
      })

      assert_receive {:backend_drained, received, elapsed}, 2_000
      assert elapsed >= 4_500 and elapsed < 7_000, "drained after #{elapsed} ms"
      assert received in 8..13, "#{received} of 16 writes arrived"
      wait_for_count(context.baseline)
    end

    @tag protocol: "sftp"
    test "revocation closes an open raw tunnel within the bound", context do
      put_proxy(recheck_interval: @bound)
      native!(context, initial: <<1>>)
      socket = tls!(context)
      :ok = :ssl.send(socket, upgrade("/1.0/instances/fixture/sftp", "sftp"))
      {head, buffered} = read_head(socket)
      assert head =~ "HTTP/1.1 101 "
      assert receive_exact(socket, buffered, 1) == <<1>>
      trust!(context.state, [])
      started = System.monotonic_time(:millisecond)
      assert drain_until_closed(socket, started + @bound + 2_000) == :closed
      assert System.monotonic_time(:millisecond) - started <= @bound + 300
      assert_receive {:backend_closed, _}, 1_000
      wait_for_count(context.baseline)
    end
  end

  describe "identity, standard clients and inventory (5.5-5.7)" do
    test "the official client discovers, lists and follows events at the gateway", context do
      IncusBackend.start!(context.sock, self(), context.guest.pem)

      %{"server" => server} = driver!(context, %{"action" => "server"})
      assert server["auth"] == "trusted"
      assert server["environment"]["addresses"] == ["127.0.0.1:#{context.port}"]
      assert server["environment"]["certificate"] == context.gateway.certificate.pem
      refute inspect(server) =~ "10.0.2.15"

      assert driver!(context, %{"action" => "list"})["instances"] == ["c1", "c2"]

      # The client builds the events WebSocket URL from the gateway remote.
      %{"event" => event} = driver!(context, %{"action" => "events"})
      assert event["metadata"]["action"] == "instance-started"
      assert_receive {:incus, "GET", "/1.0/events", _, headers}
      assert String.downcase(headers["upgrade"]) == "websocket"
    end

    test "only the canonical native paths exist, behind one listener", context do
      IncusBackend.start!(context.sock, self(), context.guest.pem)

      for path <- ["/incus/1.0", "/incus/1.0/instances", "/api/1.0", "/2.0"] do
        socket = tls!(context)
        :ok = :ssl.send(socket, request("GET", path))
        assert read(socket) =~ ~r/\AHTTP\/1.1 404/, path
      end

      refute_receive {:incus, _, _, _, _}, 100

      routes = Enum.map(MacusWeb.Router.__routes__(), & &1.path)
      refute Enum.any?(routes, &String.starts_with?(&1, "/incus"))
      assert "/" in routes

      # The library opened no listener: only Macus's gateway and this test's
      # fixture backend are Ranch listeners.
      listeners = Map.keys(:ranch.info())
      assert Macus.Gateway.Listener in listeners

      assert Enum.all?(
               listeners,
               &(&1 == Macus.Gateway.Listener or match?({IncusBackend, _}, &1))
             )

      # The official client fixture is the unpatched upstream module.
      go_mod = File.read!(Path.join(@reference_dir, "go.mod"))
      assert go_mod =~ "require github.com/lxc/incus/v7 v7.0.1"
      refute go_mod =~ ~r/^replace /m
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp put_proxy(opts) do
    Application.put_env(
      :macus,
      Macus.Proxy,
      Keyword.merge(Application.get_env(:macus, Macus.Proxy), opts)
    )
  end

  defp trust!(state, identities) do
    now = DateTime.utc_now()
    entries = for %{der: der} <- identities, do: Trust.entry(der, "fixture", "", now)
    path = Trust.path(state)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(%{"schema_version" => 1, "certificates" => entries}))
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end

  defp fill_admission(leave) do
    test = self()

    for _ <- 1..(max_exchanges() - leave) do
      holder = spawn(fn -> receive(do: (:never -> :ok)) end)
      {:ok, _slot} = Admission.acquire(@admission, holder)
      _ = test
      holder
    end
  end

  defp max_exchanges,
    do: Keyword.get(Application.get_env(:macus, Macus.Proxy, []), :max_exchanges, 64)

  defp wait_for_count(expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    count = Admission.count(@admission)

    cond do
      count == expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("admission holds #{count} slots, expected #{expected}")

      true ->
        Process.sleep(20)
        wait_for_count(expected, deadline)
    end
  end

  defp native!(context, opts) do
    start_supervised!(
      {NativeBackend,
       Map.merge(
         %{path: context.sock, protocol: context.protocol, observer: self(), initial: ""},
         Map.new(opts)
       )}
    )
  end

  # Backend session: read to EOF, then answer.
  defp reply_after_eof(observer) do
    fn socket, body ->
      {received, _elapsed} = read_to_eof(socket, byte_size(body), now_ms())
      send(observer, {:backend_eof, received})
      send(observer, {:backend_reply, :gen_tcp.send(socket, "after-eof")})
    end
  end

  # Backend session: count what arrives and how long the direction stays open.
  defp drain(observer) do
    fn socket, body ->
      {received, elapsed} = read_to_eof(socket, byte_size(body), now_ms())
      send(observer, {:backend_drained, received, elapsed})
    end
  end

  defp read_to_eof(socket, received, started) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, bytes} -> read_to_eof(socket, received + byte_size(bytes), started)
      {:error, :closed} -> {received, now_ms() - started}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp driver!(context, fields) do
    input =
      Map.merge(
        %{
          "url" => "https://127.0.0.1:#{context.port}",
          "server_cert" => context.gateway.certificate.pem,
          "tls_ca" => "",
          "client_cert" => File.read!(context.admin.certfile),
          "client_key" => File.read!(context.admin.keyfile)
        },
        fields
      )

    path = Path.join(context.root, "client-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(input))
    File.chmod!(path, 0o600)
    {output, status} = System.cmd(@driver, [path], stderr_to_stdout: true)
    File.rm!(path)
    assert status == 0, output
    Jason.decode!(output)
  end

  # TLS 1.3 to the gateway, pinning its generated certificate, as `identity`
  # (the trusted admin by default, nil for none).
  defp tls_opts(context, identity) do
    pin = context.gateway.certificate.der

    [
      versions: [:"tlsv1.3"],
      verify: :verify_peer,
      cacerts: [pin],
      verify_fun: {&pinned/3, pin},
      server_name_indication: :disable
    ] ++
      case identity do
        nil -> []
        %{certfile: certfile, keyfile: keyfile} -> [certfile: certfile, keyfile: keyfile]
      end
  end

  defp tls!(context, identity \\ :admin) do
    identity = if identity == :admin, do: context.admin, else: identity

    {:ok, socket} =
      :ssl.connect(
        ~c"127.0.0.1",
        context.port,
        tls_opts(context, identity) ++ [active: false, mode: :binary],
        5_000
      )

    socket
  end

  defp pinned(certificate, {:bad_cert, _}, pin) do
    if :public_key.pkix_encode(:OTPCertificate, certificate, :otp) == pin,
      do: {:valid, pin},
      else: {:fail, :not_pinned}
  end

  defp pinned(_certificate, {:extension, _}, pin), do: {:unknown, pin}
  defp pinned(_certificate, _event, pin), do: {:valid, pin}

  defp request(method, path, headers \\ [], body \\ "") do
    length = if body == "", do: [], else: [{"content-length", Integer.to_string(byte_size(body))}]

    [
      "#{method} #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\n",
      for({name, value} <- headers ++ length, do: [name, ": ", value, "\r\n"]),
      "connection: close\r\n\r\n",
      body
    ]
  end

  defp upgrade(path, protocol),
    do:
      "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: Upgrade\r\nupgrade: #{protocol}\r\n\r\n"

  defp read(socket, acc \\ "") do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, data} -> read(socket, acc <> data)
      {:error, _} -> acc
    end
  end

  defp read_head(socket, acc \\ "") do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {head, rest}

      [_] ->
        {:ok, data} = :ssl.recv(socket, 0, 5_000)
        read_head(socket, acc <> data)
    end
  end

  defp receive_exact(_socket, acc, size) when byte_size(acc) >= size,
    do: binary_part(acc, 0, size)

  defp receive_exact(socket, acc, size) do
    {:ok, data} = :ssl.recv(socket, 0, 5_000)
    receive_exact(socket, acc <> data, size)
  end

  defp receive_until(socket, marker, acc \\ "") do
    if String.contains?(acc, marker) do
      acc
    else
      {:ok, data} = :ssl.recv(socket, 0, 5_000)
      receive_until(socket, marker, acc <> data)
    end
  end

  defp drain_until_closed(socket, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :open
    else
      case :ssl.recv(socket, 0, remaining) do
        {:ok, _data} -> drain_until_closed(socket, deadline)
        {:error, :timeout} -> :open
        {:error, _} -> :closed
      end
    end
  end

  defp mcp_headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"mcp-protocol-version", @mcp_version},
      {"mcp-method", "tools/list"},
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"}
    ]
  end

  defp mcp_list_tools do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "list-1",
      "method" => "tools/list",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => @mcp_version,
          "io.modelcontextprotocol/clientCapabilities" => %{},
          "io.modelcontextprotocol/clientInfo" => %{"name" => "macus-test", "version" => "1.0.0"}
        }
      }
    })
  end

  # Plain HTTP over Mint, which decodes chunked responses.
  defp http!(context, method, path, headers \\ [], body \\ nil),
    do: http_as!(context, context.admin, method, path, headers, body)

  defp http_as!(context, identity, method, path, headers \\ [], body \\ nil) do
    {:ok, conn} = mint(context, identity)
    {:ok, conn, ref} = Mint.HTTP.request(conn, method, path, headers, body)
    collect(conn, ref, nil, [], "")
  end

  defp collect(conn, ref, status, headers, body) do
    {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 10_000)

    Enum.reduce_while(responses, {status, headers, body, false}, fn
      {:status, ^ref, status}, {_, h, b, _} -> {:cont, {status, h, b, false}}
      {:headers, ^ref, more}, {s, h, b, _} -> {:cont, {s, h ++ more, b, false}}
      {:data, ^ref, data}, {s, h, b, _} -> {:cont, {s, h, [b | data], false}}
      {:done, ^ref}, {s, h, b, _} -> {:halt, {s, h, b, true}}
      _, acc -> {:cont, acc}
    end)
    |> case do
      {status, headers, body, true} ->
        Mint.HTTP.close(conn)
        {status, headers, IO.iodata_to_binary(body)}

      {status, headers, body, false} ->
        collect(conn, ref, status, headers, body)
    end
  end

  defp mint(context, identity) do
    Mint.HTTP.connect(:https, "127.0.0.1", context.port,
      protocols: [:http1],
      mode: :passive,
      transport_opts: tls_opts(context, identity)
    )
  end

  # WebSockets over Mint.WebSocket.
  defp ws!(context, path) do
    {:ok, ws} = ws(context, path, context.admin)
    ws
  end

  defp ws(context, path, identity) do
    {:ok, conn} = mint(context, identity)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:wss, conn, path, [])
    {conn, status, headers, data} = upgrade_response(conn, ref, [])

    case Mint.WebSocket.new(conn, ref, status, headers) do
      {:ok, conn, websocket} ->
        ws = %{conn: conn, ref: ref, websocket: websocket, frames: []}
        {:ok, decode(ws, data)}

      {:error, _conn, _reason} ->
        {:refused, status}
    end
  end

  defp upgrade_response(conn, ref, acc) do
    {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 5_000)
    acc = acc ++ responses

    if Enum.any?(acc, &match?({:done, ^ref}, &1)) do
      [status] = for {:status, ^ref, status} <- acc, do: status
      headers = Enum.flat_map(acc, &header_list(&1, ref))
      data = for {:data, ^ref, data} <- acc, into: "", do: data
      {conn, status, headers, data}
    else
      upgrade_response(conn, ref, acc)
    end
  end

  defp header_list({:headers, ref, headers}, ref), do: headers
  defp header_list(_, _), do: []

  defp decode(ws, ""), do: ws

  defp decode(ws, data) do
    {:ok, websocket, frames} = Mint.WebSocket.decode(ws.websocket, data)
    %{ws | websocket: websocket, frames: ws.frames ++ frames}
  end

  defp send_frame(ws, frame) do
    {:ok, websocket, data} = Mint.WebSocket.encode(ws.websocket, frame)
    {:ok, conn} = Mint.WebSocket.stream_request_body(ws.conn, ws.ref, data)
    %{ws | conn: conn, websocket: websocket}
  end

  # The next `count` frames, ignoring server pings.
  defp frames(ws, count, timeout \\ 5_000) do
    ws = %{ws | frames: Enum.reject(ws.frames, &match?({:ping, _}, &1))}

    if length(ws.frames) >= count do
      {taken, rest} = Enum.split(ws.frames, count)
      {%{ws | frames: rest}, taken}
    else
      case Mint.WebSocket.recv(ws.conn, 0, timeout) do
        {:ok, conn, responses} ->
          data = for {:data, _, data} <- responses, into: "", do: data
          frames(decode(%{ws | conn: conn}, data), count, timeout)

        {:error, _conn, error, _} ->
          flunk("WebSocket ended before #{count} frames: #{inspect(error)}")
      end
    end
  end

  defp until_closed(ws, timeout) do
    case Mint.WebSocket.recv(ws.conn, 0, timeout) do
      {:ok, conn, responses} ->
        data = for {:data, _, data} <- responses, into: "", do: data
        ws = decode(%{ws | conn: conn}, data)

        if Enum.any?(ws.frames, &match?({:close, _, _}, &1)),
          do: {ws, :closed},
          else: until_closed(ws, timeout)

      {:error, conn, reason, _} when reason in [:timeout, @timeout] ->
        {%{ws | conn: conn}, :open}

      {:error, conn, _error, _} ->
        {%{ws | conn: conn}, :closed}
    end
  end

  # Sends a frame every 50 ms until the connection closes or the deadline;
  # a close says how it ended.
  defp keep_talking(ws, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      :open
    else
      ws = send_frame(ws, {:text, "tick"})

      case Mint.WebSocket.recv(ws.conn, 0, 50) do
        {:ok, conn, responses} ->
          data = for {:data, _, data} <- responses, into: "", do: data
          ws = decode(%{ws | conn: conn}, data)

          case Enum.find(ws.frames, &match?({:close, _, _}, &1)) do
            nil -> keep_talking(%{ws | frames: []}, deadline)
            close -> {:closed, close}
          end

        {:error, conn, reason, _} when reason in [:timeout, @timeout] ->
          keep_talking(%{ws | conn: conn}, deadline)

        {:error, _conn, error, _} ->
          {:closed, error}
      end
    end
  rescue
    error in MatchError -> {:closed, error}
  end
end
