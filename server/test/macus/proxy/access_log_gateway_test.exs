defmodule Macus.Proxy.AccessLogGatewayTest do
  # The access log behind Macus.Gateway's own TLS listener: records written
  # from the locked library's real exchange events, for relayed HTTP,
  # WebSocket and raw exchanges over a fixture guest incus.sock. The
  # listener name, admission, trust, logger and telemetry are global.
  use ExUnit.Case, async: false

  alias Macus.Proxy.{AccessLog, Trust}

  alias Macus.TestSupport.{
    AccessLogAudit,
    AuthFixtures,
    DexFixtures,
    IncusBackend,
    NativeBackend,
    TLSIdentity
  }

  alias Opsmaru.Incus.Gateway.Admission

  @admission Macus.Proxy.Admission
  @revision String.duplicate("ab12", 10)

  setup context do
    root = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {state_dir, uid} = AuthFixtures.state!(root)
    AuthFixtures.configure!(state_dir, uid)
    {:ok, state} = Macus.Configuration.new(state_dir)
    certs = Path.join(root, "certs")
    File.mkdir!(certs)
    File.chmod!(certs, 0o700)
    admin = TLSIdentity.self_signed(certs, "admin")
    stranger = TLSIdentity.self_signed(certs, "stranger")
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

    # As Macus.Application orders them: the log attaches before the listener.
    start_supervised!(
      {AccessLog, [state_dir: state_dir, uid: uid] ++ Map.get(context, :access_log, [])}
    )

    start_supervised!(Macus.Gateway.listener(gateway))
    start_supervised!({Macus.Gateway.Publisher, gateway})
    trust!(state, [admin])

    %{
      root: root,
      state: state,
      admin: admin,
      stranger: stranger,
      guest: guest,
      gateway: gateway,
      port: port,
      sock: Path.join(state_dir, "incus.sock"),
      log_file: Path.join(AccessLog.logs_dir(state_dir), AccessLog.file_name()),
      baseline: Admission.count(@admission)
    }
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:macus, key, value)
  defp restore(key, :error), do: Application.delete_env(:macus, key)

  @doc false
  def forward(_event, measurements, metadata, pid), do: send(pid, {:stop, measurements, metadata})

  test "the locked library's stop event carries every key the record reads", context do
    IncusBackend.start!(context.sock, self(), context.guest.pem)
    :ok = :telemetry.attach("access-keys", AccessLog.event(), &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach("access-keys") end)

    assert {200, _} = http(context, "GET", "/1.0/instances")
    assert_receive {:stop, measurements, metadata}, 2_000

    reads = AccessLog.reads()
    assert reads.metadata -- Map.keys(metadata) == []
    assert reads.measurements -- Map.keys(measurements) == []
  end

  describe "records through the gateway" do
    test "relayed, refused, anonymous, trust and WebSocket exchanges", context do
      IncusBackend.start!(context.sock, self(), context.guest.pem)
      admin = fingerprint(context.admin)

      assert {200, _} = http(context, "GET", "/1.0/instances?project=web")
      body = ~s({"description":"x"})

      assert {200, _} =
               http(context, "PUT", "/1.0/instances/c1", [{"if-match", ~s("etag-c1")}], body)

      assert {403, _} = http(context, "GET", "/1.0/instances", [], "", context.stranger)
      assert {200, _} = http(context, "GET", "/1.0", [], "", nil)
      assert {200, _} = http(context, "GET", "/1.0/certificates")

      ws = ws!(context, "/1.0/events")
      {ws, [{:text, event}]} = frames(ws, 1)
      _ws = send_frame(ws, {:close, 1000, ""})
      assert_receive {:incus_ws_closed, _}, 2_000

      [read, mutation, refused, anonymous, trust, websocket] = await_records(context, 6)

      assert %{
               "v" => 1,
               "protocol" => "http",
               "method" => "GET",
               "path" => "/1.0/instances",
               "project" => "web",
               "peer" => "127.0.0.1:" <> _,
               "certificate" => ^admin,
               "admitted_as" => "caller",
               "status" => 200,
               "outcome" => "ok",
               "reason" => nil
             } = read

      assert read["response_bytes"] > 0
      assert is_integer(read["duration_ms"])

      assert %{"method" => "PUT", "path" => "/1.0/instances/c1", "admitted_as" => "caller"} =
               mutation

      assert mutation["status"] == 200
      assert mutation["request_bytes"] == byte_size(body)

      # A refusal names the certificate that was presented, never a caller.
      assert %{
               "status" => 403,
               "outcome" => "not_sent",
               "reason" => "unauthorized",
               "admitted_as" => nil
             } = refused

      assert refused["certificate"] == fingerprint(context.stranger)

      assert %{"path" => "/1.0", "admitted_as" => "anonymous", "certificate" => nil} = anonymous
      assert %{"path" => "/1.0/certificates", "status" => 200, "certificate" => ^admin} = trust

      # A stream is one record, written when it ended.
      assert %{
               "protocol" => "websocket",
               "path" => "/1.0/events",
               "status" => 101,
               "admitted_as" => "caller"
             } = websocket

      assert websocket["response_bytes"] >= byte_size(event)

      # One run: one boot value, SEQ counting the exchanges.
      ids = Enum.map([read, mutation, refused, anonymous, trust, websocket], & &1["id"])
      [boot, "1"] = String.split(hd(ids), "-")
      assert ids == for(n <- 1..6, do: "#{boot}-#{n}")
      wait_for_count(context.baseline)
    end

    @tag protocol: "sftp"
    test "a raw upgrade is one record with its tunnelled bytes", context do
      initial = <<0, 255, 128, 13, 10>>
      native!(context, initial: initial)
      payload = :binary.copy(<<128, 0, 255, 3>>, 4_096)

      socket = tls!(context)
      :ok = :ssl.send(socket, upgrade("/1.0/instances/fixture/sftp", "sftp"))
      {head, buffered} = read_head(socket)
      assert head =~ "HTTP/1.1 101 "
      assert receive_exact(socket, buffered, byte_size(initial)) == initial
      :ok = :ssl.send(socket, payload)
      assert receive_exact(socket, "", byte_size(payload)) == payload
      :ok = :ssl.close(socket)
      assert_receive {:backend_closed, _}, 2_000

      [raw] = await_records(context, 1)

      assert %{
               "protocol" => "raw",
               "method" => "GET",
               "path" => "/1.0/instances/fixture/sftp",
               "status" => 101,
               "admitted_as" => "caller"
             } = raw

      assert raw["request_bytes"] == byte_size(payload)
      assert raw["response_bytes"] == byte_size(initial) + byte_size(payload)
      wait_for_count(context.baseline)
    end
  end

  describe "a stalled writer" do
    @describetag access_log: [drop_qlen: 2]

    test "relayed HTTP and WebSocket exchanges keep their responses and slots", context do
      IncusBackend.start!(context.sock, self(), context.guest.pem)

      stalled(context, 5, fn ->
        for _ <- 1..3 do
          assert {200, listed} = http(context, "GET", "/1.0/instances")
          assert Jason.decode!(listed)["metadata"] == ["/1.0/instances/c1", "/1.0/instances/c2"]
        end

        assert {403, _} = http(context, "GET", "/1.0/instances", [], "", context.stranger)

        ws = ws!(context, "/1.0/operations/op1/websocket?secret=s3")
        {ws, [{:text, _control}]} = frames(ws, 1)
        binary = :crypto.strong_rand_bytes(50_000)
        ws = send_frame(ws, {:binary, binary})
        {ws, [{:binary, ^binary}]} = frames(ws, 1)
        ws = send_frame(ws, {:text, "close-me"})
        {_ws, [{:close, 4000, "bye"}]} = frames(ws, 1)
      end)
    end

    @tag protocol: "nbd"
    test "raw tunnels keep their bytes and slots", context do
      initial = <<0, 1, 255>>
      native!(context, initial: initial)
      payload = :binary.copy(<<0, 255, 2, 128>>, 16_384)

      stalled(context, 3, fn ->
        for _ <- 1..3 do
          socket = tls!(context)
          :ok = :ssl.send(socket, upgrade("/1.0/instances/fixture/nbd", "nbd"))
          {head, buffered} = read_head(socket)
          assert head =~ "HTTP/1.1 101 "
          assert receive_exact(socket, buffered, byte_size(initial)) == initial
          :ok = :ssl.send(socket, payload)
          assert receive_exact(socket, "", byte_size(payload)) == payload
          :ok = :ssl.close(socket)
          assert_receive {:backend_closed, _}, 2_000
        end
      end)
    end
  end

  describe "redaction" do
    test "no credential, query, secret, header, body or certificate reaches the log", context do
      IncusBackend.start!(context.sock, self(), context.guest.pem)
      {token, record} = AuthFixtures.token!(["incus.native.read"])
      AuthFixtures.store!(Path.dirname(Path.dirname(Trust.path(context.state))), [record])

      marks = %{
        query: "QUERYMARK7f3a",
        operation: "OPSECRET91c2",
        image: "IMGSECRET55aa",
        header: "HEADERMARK1d4e",
        body: "BODYMARK88b1",
        enrollment: "ENROLLMARK0c6f",
        basic: Base.encode64("user:BASICMARK42")
      }

      bearer = [{"authorization", "Bearer " <> token}]

      # Credentials in headers, with and without a certificate.
      http(context, "GET", "/1.0/instances", bearer)
      http(context, "GET", "/1.0/instances", bearer, "", nil)
      http(context, "GET", "/1.0/instances", [{"authorization", "Basic " <> marks.basic}])
      http(context, "GET", "/1.0/instances", [{"x-fixture", marks.header}])
      # Query strings and secret parameters.
      http(context, "GET", "/1.0/instances?project=web&filter=" <> marks.query)
      http(context, "GET", "/1.0/images/abc?secret=" <> marks.image)
      http(context, "GET", "/1.0/operations/op9/wait?secret=" <> marks.operation, [], "", nil)
      # Bodies, including an enrollment attempt from an untrusted certificate.
      http(context, "PUT", "/1.0/instances/c1", [], ~s({"description":"#{marks.body}"}))

      http(
        context,
        "POST",
        "/1.0/certificates",
        [{"content-type", "application/json"}],
        ~s({"type":"client","trust_token":"#{marks.enrollment}"}),
        context.stranger
      )

      # A stream whose URL carries an operation secret and whose frames carry data.
      ws = ws!(context, "/1.0/operations/op1/websocket?secret=s3" <> marks.operation)
      {ws, _} = frames(ws, 1)
      ws = send_frame(ws, {:text, marks.body})
      {ws, _} = frames(ws, 1)
      _ws = send_frame(ws, {:close, 1000, ""})

      records = await_records(context, 10)
      assert Enum.all?(records, &(Map.keys(&1) -- AccessLogAudit.keys() == []))
      refute Enum.any?(records, &String.contains?(&1["path"] || "", "?"))

      secrets =
        Map.values(marks) ++
          [token, pem_body(context.admin), pem_body(context.stranger), pem_body(context.guest)]

      assert AccessLogAudit.violations(File.read!(context.log_file), secrets) == []
    end
  end

  # -- helpers ---------------------------------------------------------------

  # Runs `exchanges` while the log writer is suspended, so nothing is
  # written, and holds them to the bounds they have with a running writer.
  # With `drop_qlen: 2` two records queue and the rest are dropped.
  defp stalled(context, count, exchanges) do
    writer = Process.whereis(:"logger_std_h_#{AccessLog.handler_id()}")
    before = AccessLog.stats()
    :ok = :sys.suspend(writer)
    started = System.monotonic_time(:millisecond)

    try do
      exchanges.()
      # No exchange waited for the writer, and every slot came back.
      assert System.monotonic_time(:millisecond) - started < 3_000
      wait_for_count(context.baseline)
      await_stat(:dropped, before.dropped + count - 2)
      assert sync_lines(context, 0) == []
    after
      :ok = :sys.resume(writer)
    end

    assert length(await_records(context, 2)) == 2
    # The next record written carries the count of the dropped ones.
    assert {status, _} = http(context, "GET", "/1.0", [], "", nil)
    assert status == 200
    [_, _, marked] = await_records(context, 3)
    assert marked["dropped_before"] == count - 2
    assert %{pending: 0, errors: errors} = AccessLog.stats()
    assert errors == before.errors
  end

  defp await_stat(key, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 3_000
    value = Map.fetch!(AccessLog.stats(), key)

    cond do
      value == expected ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("#{key} is #{value}, not #{expected}")

      true ->
        Process.sleep(20) && await_stat(key, expected, deadline)
    end
  end

  # Records are written by the library's observer after the exchange ended.
  defp await_records(context, count, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 3_000
    lines = sync_lines(context)

    cond do
      length(lines) == count ->
        Enum.map(lines, &Jason.decode!/1)

      System.monotonic_time(:millisecond) > deadline ->
        flunk(
          "the log holds #{length(lines)} records, expected #{count}:\n" <> Enum.join(lines, "\n")
        )

      true ->
        Process.sleep(20)
        await_records(context, count, deadline)
    end
  end

  defp sync_lines(context, sync \\ 1) do
    if sync == 1, do: :ok = :logger_std_h.filesync(AccessLog.handler_id())

    case File.read(context.log_file) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp fingerprint(%{der: der}), do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)

  # A stretch of the certificate's base64 body, long enough to be unique.
  defp pem_body(%{der: der}), do: der |> Base.encode64() |> binary_part(40, 32)

  defp trust!(state, identities) do
    now = DateTime.utc_now()
    entries = for %{der: der} <- identities, do: Trust.entry(der, "fixture", "", now)
    path = Trust.path(state)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(%{"schema_version" => 1, "certificates" => entries}))
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
  end

  defp wait_for_count(expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000
    count = Admission.count(@admission)

    cond do
      count == expected -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("admission holds #{count} slots")
      true -> Process.sleep(20) && wait_for_count(expected, deadline)
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

  defp identity(context, :admin), do: context.admin
  defp identity(_context, identity), do: identity

  defp tls!(context, identity \\ :admin) do
    {:ok, socket} =
      :ssl.connect(
        ~c"127.0.0.1",
        context.port,
        tls_opts(context, identity(context, identity)) ++ [active: false, mode: :binary],
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

  defp upgrade(path, protocol),
    do:
      "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\nconnection: Upgrade\r\nupgrade: #{protocol}\r\n\r\n"

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

  # Plain HTTP over Mint, which decodes chunked responses.
  defp http(context, method, path, headers \\ [], body \\ "", identity \\ :admin) do
    {:ok, conn} = mint(context, identity(context, identity))
    body = if body == "", do: nil, else: body
    {:ok, conn, ref} = Mint.HTTP.request(conn, method, path, headers, body)
    collect(conn, ref, nil, "")
  end

  defp collect(conn, ref, status, body) do
    {:ok, conn, responses} = Mint.HTTP.recv(conn, 0, 10_000)

    Enum.reduce_while(responses, {status, body, false}, fn
      {:status, ^ref, status}, {_, b, _} -> {:cont, {status, b, false}}
      {:data, ^ref, data}, {s, b, _} -> {:cont, {s, [b | data], false}}
      {:done, ^ref}, {s, b, _} -> {:halt, {s, b, true}}
      _, acc -> {:cont, acc}
    end)
    |> case do
      {status, body, true} ->
        Mint.HTTP.close(conn)
        {status, IO.iodata_to_binary(body)}

      {status, body, false} ->
        collect(conn, ref, status, body)
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
    {:ok, conn} = mint(context, context.admin)
    {:ok, conn, ref} = Mint.WebSocket.upgrade(:wss, conn, path, [])
    {conn, status, headers, data} = upgrade_response(conn, ref, [])
    {:ok, conn, websocket} = Mint.WebSocket.new(conn, ref, status, headers)
    decode(%{conn: conn, ref: ref, websocket: websocket, frames: []}, data)
  end

  defp upgrade_response(conn, ref, acc) do
    {:ok, conn, responses} = Mint.WebSocket.recv(conn, 0, 5_000)
    acc = acc ++ responses

    if Enum.any?(acc, &match?({:done, ^ref}, &1)) do
      [status] = for {:status, ^ref, status} <- acc, do: status
      headers = for {:headers, ^ref, headers} <- acc, header <- headers, do: header
      data = for {:data, ^ref, data} <- acc, into: "", do: data
      {conn, status, headers, data}
    else
      upgrade_response(conn, ref, acc)
    end
  end

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

  defp frames(%{frames: frames} = ws, count) when length(frames) >= count do
    {taken, rest} = Enum.split(frames, count)
    {%{ws | frames: rest}, taken}
  end

  defp frames(ws, count) do
    {:ok, conn, responses} = Mint.WebSocket.recv(ws.conn, 0, 5_000)
    data = for {:data, ref, data} <- responses, ref == ws.ref, into: "", do: data
    frames(decode(%{ws | conn: conn}, data), count)
  end
end
