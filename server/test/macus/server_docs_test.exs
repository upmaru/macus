defmodule Macus.ServerDocsTest do
  # docs/server.md examples against isolated TLS fixtures, and credential
  # redaction in captured server logs. Global build, gateway and logger state.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Macus.{Build, Configuration, Gateway}
  alias Macus.TestSupport.{AuthFixtures, TLSIdentity}

  @doc_path Path.expand("../../../docs/server.md", __DIR__)
  @external_resource @doc_path
  @revision String.duplicate("cd56", 10)

  setup do
    root = Path.join(System.tmp_dir!(), "macus-docs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    state_dir = Path.join(root, "state")
    File.mkdir!(state_dir)
    File.chmod!(state_dir, 0o700)
    {:ok, state} = Configuration.new(state_dir)
    %File.Stat{uid: uid} = File.lstat!(state_dir)
    certs = Path.join(root, "certs")
    File.mkdir!(certs)
    File.chmod!(certs, 0o700)

    build = Application.get_env(:macus, Build)
    Application.put_env(:macus, Build, revision: @revision)

    on_exit(fn ->
      if build,
        do: Application.put_env(:macus, Build, build),
        else: Application.delete_env(:macus, Build)

      File.rm_rf!(root)
    end)

    %{state: state, uid: uid, certs: certs, server: Path.join(state_dir, "server")}
  end

  defp prepare(context) do
    Gateway.prepare(
      state: context.state,
      uid: context.uid,
      expected_revision: @revision,
      now: DateTime.utc_now()
    )
  end

  defp write_config!(context, fields) do
    File.mkdir_p!(context.server)
    File.chmod!(context.server, 0o700)
    path = Path.join(context.server, "gateway.json")
    File.write!(path, Jason.encode!(fields))
    File.chmod!(path, 0o600)
  end

  defp doc_block(language) do
    [_, block] = Regex.run(~r/```#{language}\n(.*?)```/s, File.read!(@doc_path))
    block
  end

  test "the documented LAN gateway.json serves the advertised identity", context do
    example = Jason.decode!(doc_block("json"))

    assert example == %{
             "schema_version" => 1,
             "bind_address" => "192.168.1.20",
             "advertised_url" => "https://macus.example.net:8443",
             "certificate_file" => "/Users/me/certs/macus.example.net.pem",
             "key_file" => "/Users/me/certs/macus.example.net.key"
           }

    # The same file with the paths of an isolated operator identity for the
    # documented host.
    identity = TLSIdentity.generate(context.certs, "macus.example.net", "macus.example.net")

    write_config!(context, %{
      example
      | "certificate_file" => identity.certfile,
        "key_file" => identity.keyfile
    })

    assert {:ok, gateway} = prepare(context)
    assert gateway.config.url == "https://macus.example.net:8443"
    assert gateway.config.address == "macus.example.net:8443"
    assert gateway.config.bind_ip == {192, 168, 1, 20}
    assert gateway.certificate.der == identity.der
    assert Gateway.Config.identity_scope(gateway.config) == :local
    refute File.exists?(Path.join(context.server, "gateway.key"))

    # A certificate for another host is refused, as the page says.
    other = TLSIdentity.generate(context.certs, "other", "other.example.net")

    write_config!(context, %{
      example
      | "certificate_file" => other.certfile,
        "key_file" => other.keyfile
    })

    assert prepare(context) == {:error, :identity_mismatch}
  end

  test "the documented defaults are loopback with the generated identity", context do
    assert {:ok, gateway} = prepare(context)
    assert gateway.config.url == "https://127.0.0.1:8443"
    assert gateway.config.bind_ip == {127, 0, 0, 1}

    assert File.lstat!(Path.join(context.server, "gateway.key")).mode |> Bitwise.band(0o777) ==
             0o600

    assert :public_key.pkix_verify_hostname(gateway.certificate.der, dns_id: ~c"localhost")
    assert Macus.Proxy.__info__(:functions) |> Keyword.has_key?(:gateway)
  end

  @tag capture_log: true
  test "credentials never reach the server log", context do
    level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: level) end)

    gateway_env = Application.get_env(:macus, Gateway)
    on_exit(fn -> Application.put_env(:macus, Gateway, gateway_env || []) end)

    write_config!(context, %{"schema_version" => 1, "port" => free_port()})
    {:ok, gateway} = prepare(context)
    start_supervised!(Gateway.listener(gateway))
    start_supervised!({Gateway.Publisher, gateway})

    # A revoked bearer token, an enrollment token and secrets in a query.
    AuthFixtures.configure!(context.state.state_dir, context.uid)
    {bearer, record} = AuthFixtures.token!(["incus.read"])

    AuthFixtures.store!(context.state.state_dir, [
      %{record | "revoked_at" => "2026-01-01T00:00:00Z"}
    ])

    trust_token = Base.encode64(:crypto.strong_rand_bytes(48))
    query_secret = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    laptop = TLSIdentity.self_signed(context.certs, "laptop")
    port = gateway.config.port
    pin = gateway.certificate.der

    log =
      capture_log([level: :debug], fn ->
        assert request(port, pin, [], "POST /mcp", [{"authorization", "Bearer " <> bearer}], "{}") =~
                 ~r/\AHTTP\/1.1 401/

        body = Jason.encode!(%{"type" => "client", "trust_token" => trust_token})

        assert request(
                 port,
                 pin,
                 [certfile: laptop.certfile, keyfile: laptop.keyfile],
                 "POST /1.0/certificates",
                 [{"content-type", "application/json"}],
                 body
               ) =~ ~r/\AHTTP\/1.1 (400|403)/

        assert request(
                 port,
                 pin,
                 [],
                 "GET /1.0/instances?token=#{query_secret}&secret=#{query_secret}",
                 [],
                 ""
               ) =~ ~r/\AHTTP\/1.1 403/

        Logger.flush()
      end)

    # The requests were logged, with their credentials filtered out.
    assert log =~ "/1.0/instances"
    assert log =~ "/mcp"
    [_, _, secret] = String.split(bearer, ".")

    for value <- [bearer, secret, trust_token, query_secret] do
      refute log =~ value
    end

    # Routes that parse parameters log credential-named ones as [FILTERED].
    assert Phoenix.Logger.filter_values(%{
             "trust_token" => trust_token,
             "client_secret" => query_secret,
             "api_key" => query_secret,
             "password" => query_secret,
             "name" => "laptop"
           }) == %{
             "trust_token" => "[FILTERED]",
             "client_secret" => "[FILTERED]",
             "api_key" => "[FILTERED]",
             "password" => "[FILTERED]",
             "name" => "laptop"
           }
  end

  test "the documented native paths and stream limits are the gateway's" do
    [_, native] = String.split(File.read!(@doc_path), "## Native Incus\n", parts: 2)
    [native, _] = String.split(native, "\n## ", parts: 2)

    limits = Macus.Proxy.limits()

    connection =
      Opsmaru.Incus.Connection.unix!("/private/tmp/macus-docs.sock", owner: {:macus, "docs"})

    row = fn name ->
      [_, value] = Regex.run(~r/^\| #{name} \| ([^|]+) \|/m, native)
      String.trim(value)
    end

    assert row.("Concurrent native exchanges") == Integer.to_string(limits.max_exchanges)
    assert row.("Idle stream") =~ "#{div(limits.idle_timeout, 1000)} seconds"
    assert limits.max_lifetime == 3_600_000 and row.("Exchange lifetime") == "1 hour"
    assert connection.max_stream_bytes == 1_073_741_824 and connection.max_chunk_bytes == 65_536
    assert row.("Body per stream") == "1 GiB, read 64 KiB at a time"
    assert row.("Revocation and expiry") == "#{div(limits.recheck_interval, 1000)} seconds"

    # The raw routes named are exactly the shared handler's.
    assert native =~ "`GET /1.0/instances/NAME/sftp` and `/nbd`"
    assert native =~ "`GET /1.0/storage-pools/POOL/volumes/TYPE/NAME/sftp` and `/nbd`"
    assert native =~ "There is no `/incus`"
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp request(port, pin, opts, request_line, headers, body) do
    {:ok, socket} =
      :ssl.connect(
        ~c"127.0.0.1",
        port,
        [
          versions: [:"tlsv1.3"],
          verify: :verify_peer,
          cacerts: [pin],
          verify_fun: {&pinned/3, pin},
          active: false,
          mode: :binary
        ] ++ opts,
        5_000
      )

    header_lines = Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)

    :ok =
      :ssl.send(
        socket,
        "#{request_line} HTTP/1.1\r\nhost: 127.0.0.1\r\n#{header_lines}content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
      )

    read(socket, "")
  end

  defp read(socket, acc) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, data} -> read(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp pinned(certificate, {:bad_cert, :selfsigned_peer}, pin) do
    if :public_key.pkix_encode(:OTPCertificate, certificate, :otp) == pin,
      do: {:valid, pin},
      else: {:fail, :not_pinned}
  end

  defp pinned(_certificate, {:bad_cert, reason}, _pin), do: {:fail, reason}
  defp pinned(_certificate, {:extension, _}, pin), do: {:unknown, pin}
  defp pinned(_certificate, _event, pin), do: {:valid, pin}
end
