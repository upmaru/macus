defmodule Macus.GatewayTest do
  # Global build and gateway configuration, and one fixed listener name.
  use ExUnit.Case, async: false

  alias Macus.{Build, Configuration, Gateway}
  alias Macus.Gateway.Certificate
  alias Macus.Proxy.Trust
  alias Macus.TestSupport.TLSIdentity

  @revision String.duplicate("ab12", 10)

  setup do
    root = Path.join(System.tmp_dir!(), "macus-gateway-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    state_dir = Path.join(root, "state")
    File.mkdir!(state_dir)
    File.chmod!(state_dir, 0o700)
    {:ok, state} = Configuration.new(state_dir)
    %File.Stat{uid: uid} = File.lstat!(state_dir)

    build = Application.get_env(:macus, Build)
    gateway = Application.get_env(:macus, Gateway)
    Application.put_env(:macus, Build, revision: @revision)

    on_exit(fn ->
      restore(Build, build)
      restore(Gateway, gateway)
      File.chmod(root, 0o700)
      File.rm_rf!(root)
    end)

    %{root: root, state: state, uid: uid, server: Path.join(state_dir, "server")}
  end

  defp restore(key, nil), do: Application.delete_env(:macus, key)
  defp restore(key, value), do: Application.put_env(:macus, key, value)

  defp prepare(context, opts \\ []) do
    Gateway.prepare(
      Keyword.merge(
        [
          state: context.state,
          uid: context.uid,
          expected_revision: @revision,
          now: DateTime.utc_now()
        ],
        opts
      )
    )
  end

  defp configure!(context, fields) do
    File.mkdir_p!(context.server)
    File.chmod!(context.server, 0o700)
    path = Path.join(context.server, "gateway.json")
    File.write!(path, Jason.encode!(Map.put_new(fields, "schema_version", 1)))
    File.chmod!(path, 0o600)
    path
  end

  # A port nothing listens on; the listener binds it explicitly.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp serve!(context, fields \\ %{}) do
    configure!(context, Map.put_new(fields, "port", free_port()))
    {:ok, gateway} = prepare(context)
    start_supervised!(Gateway.listener(gateway))
    start_supervised!({Gateway.Publisher, gateway})
    gateway
  end

  # Connects as clients of a self-signed gateway do: by pinning its exact
  # certificate (OTP otherwise refuses a self-signed leaf).
  defp tls(port, pin, opts \\ []) do
    :ssl.connect(
      ~c"127.0.0.1",
      port,
      Keyword.merge(
        [
          versions: [:"tlsv1.3"],
          verify: :verify_peer,
          cacerts: [pin],
          verify_fun: {&pinned/3, pin},
          active: false,
          mode: :binary
        ],
        opts
      ),
      5_000
    )
  end

  defp pinned(certificate, {:bad_cert, :selfsigned_peer}, pin) do
    if :public_key.pkix_encode(:OTPCertificate, certificate, :otp) == pin,
      do: {:valid, pin},
      else: {:fail, :not_pinned}
  end

  defp pinned(_certificate, {:bad_cert, reason}, _pin), do: {:fail, reason}
  defp pinned(_certificate, {:extension, _}, pin), do: {:unknown, pin}
  defp pinned(_certificate, _event, pin), do: {:valid, pin}

  defp get(socket, path, headers \\ "") do
    :ok =
      :ssl.send(
        socket,
        "GET #{path} HTTP/1.1\r\nhost: 127.0.0.1\r\n#{headers}connection: close\r\n\r\n"
      )

    read(socket, "")
  end

  defp read(socket, acc) do
    case :ssl.recv(socket, 0, 5_000) do
      {:ok, data} -> read(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  describe "build identity" do
    test "serving needs a known revision equal to the launcher's and the locked library" do
      assert Build.check(@revision) == :ok
      assert Build.check(String.duplicate("cd34", 10)) == {:error, :revision_mismatch}
      assert Build.check(nil) == {:error, :missing_revision}
      assert Build.check("not-a-revision") == {:error, :missing_revision}
      assert Build.check(@revision, "0.2.0") == {:error, :dependency_mismatch}
      assert Build.check(@revision, nil) == {:error, :dependency_mismatch}

      Application.put_env(:macus, Build, revision: nil)
      assert Build.check(@revision) == {:error, :missing_revision}
    end

    test "the recorded library identity is the locked one" do
      %{opsmaru_incus: %{version: version, checksum: checksum}} = Build.identity()

      {lock, _} =
        Path.expand("../../mix.lock", __DIR__)
        |> File.read!()
        |> Code.string_to_quoted!(emit_warnings: false)
        |> Code.eval_quoted()

      assert {:hex, :opsmaru_incus, ^version, _, _, _, _, ^checksum} = lock.opsmaru_incus
      assert to_string(Application.spec(:opsmaru_incus, :vsn)) == version
    end
  end

  describe "preflight" do
    test "defaults to loopback with an identity generated once", context do
      assert {:ok, gateway} = prepare(context)

      assert %{bind_ip: {127, 0, 0, 1}, port: 8443, url: "https://127.0.0.1:8443"} =
               gateway.config

      assert gateway.config.address == "127.0.0.1:8443"
      assert gateway.build.revision == @revision

      for name <- ["gateway.crt", "gateway.key"] do
        assert %File.Stat{mode: mode} = File.lstat!(Path.join(context.server, name))
        assert Bitwise.band(mode, 0o777) == 0o600
      end

      assert %File.Stat{mode: mode} = File.lstat!(context.server)
      assert Bitwise.band(mode, 0o777) == 0o700

      # The identity is reused, never regenerated.
      assert {:ok, again} = prepare(context)
      assert again.certificate.fingerprint == gateway.certificate.fingerprint
      refute File.exists?(Gateway.metadata_path(context.state))
    end

    test "an IPv6 loopback bind is advertised as itself", context do
      configure!(context, %{"bind_address" => "::1", "port" => 9443})
      assert {:ok, gateway} = prepare(context)
      assert gateway.config.url == "https://[::1]:9443"
      assert gateway.config.address == "[::1]:9443"
    end

    test "a missing or mismatched build fails before any state is created", context do
      assert prepare(context, expected_revision: nil) == {:error, :missing_revision}

      assert prepare(context, expected_revision: String.duplicate("0", 40)) ==
               {:error, :revision_mismatch}

      refute File.exists?(context.server)
    end

    test "unsafe or foreign state fails", context do
      assert prepare(context, uid: context.uid + 1) == {:error, :unsafe_state}

      File.chmod!(context.state.state_dir, 0o770)
      assert prepare(context) == {:error, :unsafe_state}
      File.chmod!(context.state.state_dir, 0o700)

      File.chmod!(context.root, 0o777)
      assert prepare(context) == {:error, :unsafe_state}
      File.chmod!(context.root, 0o700)

      File.mkdir!(context.server)
      File.chmod!(context.server, 0o755)
      assert prepare(context) == {:error, :unsafe_state}
      File.rm_rf!(context.server)

      link = Path.join(context.root, "link")
      File.ln_s!(context.state.state_dir, link)
      {:ok, linked} = Configuration.new(link)
      assert prepare(context, state: linked) == {:error, :unsafe_state}

      {:ok, missing} = Configuration.new(Path.join(context.root, "missing"))
      assert prepare(context, state: missing) == {:error, :missing_state}
      refute File.exists?(context.server)
    end

    test "configuration never binds every interface or guesses a public identity", context do
      for {fields, error} <- [
            {%{"bind_address" => "0.0.0.0"}, :wildcard_bind},
            {%{"bind_address" => "::"}, :wildcard_bind},
            {%{"bind_address" => "192.168.1.20"}, :advertised_url_required},
            {%{"bind_address" => "localhost"}, {:invalid_configuration, "bind_address"}},
            {%{"bind_address" => "224.0.0.1"}, {:invalid_configuration, "bind_address"}},
            {%{"port" => 0}, {:invalid_configuration, "port"}},
            {%{"port" => 65_536}, {:invalid_configuration, "port"}},
            {%{"advertised_url" => "http://127.0.0.1:8443"},
             {:invalid_configuration, "advertised_url"}},
            {%{"advertised_url" => "https://127.0.0.1:8443/macus"},
             {:invalid_configuration, "advertised_url"}},
            {%{"advertised_url" => "https://me@127.0.0.1:8443"},
             {:invalid_configuration, "advertised_url"}},
            {%{"advertised_url" => "https://0.0.0.0:8443"},
             {:invalid_configuration, "advertised_url"}},
            {%{"bind_address" => "192.168.1.20", "advertised_url" => "https://localhost:8443"},
             {:invalid_configuration, "advertised_url"}},
            {%{"certificate_file" => "relative.pem", "key_file" => "/k.pem"},
             {:invalid_configuration, "certificate_file"}},
            {%{"certificate_file" => "/c.pem"}, {:invalid_configuration, "key_file"}},
            {%{"schema_version" => 2}, {:invalid_configuration, "schema_version"}},
            {%{"listen" => "0.0.0.0:8443"}, {:invalid_configuration, "listen"}}
          ] do
        configure!(context, fields)
        assert prepare(context) == {:error, error}, inspect(fields)
      end

      refute File.exists?(Path.join(context.server, "gateway.key"))
    end

    test "the configuration file must be owner-private JSON", context do
      path = configure!(context, %{})
      File.chmod!(path, 0o644)
      assert prepare(context) == {:error, :unsafe_configuration}

      File.write!(path, "{")
      File.chmod!(path, 0o600)
      assert prepare(context) == {:error, {:invalid_configuration, "gateway.json"}}
    end

    test "a published identity is never silently regenerated", context do
      assert {:ok, gateway} = prepare(context)
      :ok = Gateway.publish(gateway, DateTime.utc_now())

      File.rm!(Path.join(context.server, "gateway.crt"))
      assert prepare(context) == {:error, :identity_incomplete}

      File.rm!(Path.join(context.server, "gateway.key"))
      assert prepare(context) == {:error, :identity_missing}
    end

    test "an operator identity must name the advertised host and match its key", context do
      lan = TLSIdentity.generate(context.root, "lan", "macus.example.net")
      other = TLSIdentity.self_signed(context.root, "other", "macus.example.net")

      fields = %{
        "bind_address" => "192.168.1.20",
        "advertised_url" => "https://macus.example.net:8443",
        "certificate_file" => lan.certfile,
        "key_file" => lan.keyfile
      }

      configure!(context, fields)
      assert {:ok, gateway} = prepare(context)
      assert gateway.certificate.der == lan.der
      assert gateway.config.address == "macus.example.net:8443"
      refute File.exists?(Path.join(context.server, "gateway.key"))

      configure!(context, %{fields | "advertised_url" => "https://wrong.example.net:8443"})
      assert prepare(context) == {:error, :identity_mismatch}

      configure!(context, %{fields | "key_file" => other.keyfile})
      assert prepare(context) == {:error, :key_mismatch}

      configure!(context, fields)

      assert prepare(context, now: DateTime.add(DateTime.utc_now(), 3, :day)) ==
               {:error, :certificate_not_current}

      File.chmod!(lan.keyfile, 0o640)
      assert prepare(context) == {:error, :unsafe_key}
      File.chmod!(lan.keyfile, 0o600)

      File.chmod!(lan.certfile, 0o666)
      assert prepare(context) == {:error, :unsafe_certificate}
    end

    test "the default identity names only loopback", context do
      configure!(context, %{
        "bind_address" => "192.168.1.20",
        "advertised_url" => "https://macus.example.net:8443"
      })

      assert prepare(context) == {:error, :identity_mismatch}
    end

    test "loopback and private-network listeners use the local identity scope", context do
      url = "https://macus.example.net:8443"

      for {bind, scope} <- [
            {nil, :local},
            {"::1", :local},
            {"10.1.2.3", :local},
            {"172.16.0.9", :local},
            {"192.168.1.20", :local},
            {"100.64.0.7", :local},
            {"169.254.1.1", :local},
            {"fd12:3456::1", :local},
            {"fe80::1", :local},
            {"172.32.0.1", :public},
            {"100.128.0.1", :public},
            {"203.0.113.5", :public},
            {"2001:db8::5", :public}
          ] do
        fields =
          if bind,
            do: %{"schema_version" => 1, "bind_address" => bind, "advertised_url" => url},
            else: %{"schema_version" => 1}

        assert {:ok, config} = Gateway.Config.build(context.state, fields)
        assert Gateway.Config.identity_scope(config) == scope, inspect(bind)
      end
    end

    test "the generated certificate is a P-384 server certificate for loopback", context do
      certfile = Path.join(context.root, "c.pem")
      keyfile = Path.join(context.root, "k.pem")
      assert Certificate.generate(certfile, keyfile, DateTime.utc_now()) == :ok
      assert Certificate.generate(certfile, keyfile, DateTime.utc_now()) == {:error, :exists}

      {text, 0} = System.cmd("openssl", ["x509", "-in", certfile, "-noout", "-text"])
      assert text =~ "ecdsa-with-SHA384"
      assert text =~ "384 bit"
      assert text =~ "CA:FALSE"
      assert text =~ "TLS Web Server Authentication"
      assert text =~ "DNS:localhost, IP Address:127.0.0.1, IP Address:0:0:0:0:0:0:0:1"

      for host <- ["127.0.0.1", "::1", "localhost"] do
        assert {:ok, _} =
                 Certificate.load(
                   %{certfile: certfile, keyfile: keyfile},
                   context.uid,
                   host,
                   DateTime.utc_now()
                 )
      end
    end
  end

  describe "serving" do
    test "nothing listens unless serving, whatever PHX_SERVER and PORT say", context do
      System.put_env("PHX_SERVER", "true")
      System.put_env("PORT", "4000")

      try do
        Application.put_env(:macus, :state_dir, context.state.state_dir)
        Application.delete_env(:macus, Gateway)
        assert Gateway.children() == {:ok, []}
        refute File.exists?(context.server)
      after
        System.delete_env("PHX_SERVER")
        System.delete_env("PORT")
      end
    end

    test "a failed preflight returns no listener and leaves the port closed", context do
      port = free_port()
      configure!(context, %{"port" => port, "bind_address" => "0.0.0.0"})
      previous = Application.get_env(:macus, :state_dir)
      Application.put_env(:macus, :state_dir, context.state.state_dir)

      Application.put_env(:macus, Gateway,
        serve: true,
        expected_revision: @revision,
        owner_uid: context.uid
      )

      try do
        assert Gateway.children() == {:error, :wildcard_bind}
        assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [], 1_000)
      after
        Application.put_env(:macus, :state_dir, previous)
      end
    end

    test "serves TLS 1.3 on the configured loopback address and publishes the endpoint",
         context do
      gateway = serve!(context)
      port = gateway.config.port
      assert {{127, 0, 0, 1}, ^port} = :ranch.get_addr(Gateway.Listener)

      assert {:ok, socket} = tls(port, gateway.certificate.der)
      assert {:ok, [protocol: :"tlsv1.3"]} = :ssl.connection_information(socket, [:protocol])
      # An unknown route is answered over the same listener.
      assert get(socket, "/no-such-route") =~ ~r/\AHTTP\/1.1 404/

      path = Gateway.metadata_path(context.state)
      assert %File.Stat{mode: mode} = File.lstat!(path)
      assert Bitwise.band(mode, 0o777) == 0o600
      metadata = path |> File.read!() |> Jason.decode!()

      assert metadata["url"] == "https://127.0.0.1:#{port}"
      assert metadata["addresses"] == ["127.0.0.1:#{port}"]
      assert metadata["listen"] == "127.0.0.1:#{port}"
      assert metadata["certificate"] == gateway.certificate.pem
      assert metadata["certificate_fingerprint"] == Trust.fingerprint(gateway.certificate.der)
      assert metadata["pid"] == System.pid()
      assert metadata["build"]["revision"] == @revision

      assert metadata["build"]["opsmaru_incus"] == %{
               "version" => Build.identity().opsmaru_incus.version,
               "checksum" => Build.identity().opsmaru_incus.checksum
             }

      refute Enum.any?(Map.keys(metadata), &(&1 =~ ~r/key|secret|token|sock/))
      assert Gateway.current() == gateway
    end

    test "clients see the gateway identity and cannot be redirected to another", context do
      gateway = serve!(context)
      port = gateway.config.port
      other = TLSIdentity.self_signed(context.root, "other", "localhost")

      # A client pinning another certificate refuses the gateway.
      assert {:error, {:tls_alert, {:handshake_failure, ~c"TLS client" ++ _ = reason}}} =
               tls(port, other.der)

      assert to_string(reason) =~ "not_pinned"

      # It serves exactly its own certificate, which names loopback only.
      assert {:ok, socket} = tls(port, gateway.certificate.der)
      assert {:ok, served} = :ssl.peercert(socket)
      assert served == gateway.certificate.der
      assert :public_key.pkix_verify_hostname(served, ip: {127, 0, 0, 1})
      refute :public_key.pkix_verify_hostname(served, dns_id: ~c"macus.example.net")
    end

    test "older TLS and cleartext are refused", context do
      gateway = serve!(context)
      port = gateway.config.port

      assert {:error, _} = tls(port, gateway.certificate.der, versions: [:"tlsv1.2"])

      {:ok, plain} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
      :ok = :gen_tcp.send(plain, "GET / HTTP/1.1\r\nhost: 127.0.0.1\r\n\r\n")

      response =
        case :gen_tcp.recv(plain, 0, 5_000) do
          {:ok, data} -> data
          {:error, _} -> ""
        end

      refute response =~ "HTTP/"
    end

    test "client certificates are collected and trusted only by the gateway trust store",
         context do
      gateway = serve!(context)
      laptop = TLSIdentity.self_signed(context.root, "laptop")
      stranger = TLSIdentity.self_signed(context.root, "stranger")

      path = Trust.path(context.state)
      entry = Trust.entry(laptop.der, "laptop", "", DateTime.utc_now())
      File.write!(path, Jason.encode!(%{"schema_version" => 1, "certificates" => [entry]}))
      File.chmod!(path, 0o600)

      request = fn opts ->
        {:ok, socket} = tls(gateway.config.port, gateway.certificate.der, opts)
        get(socket, "/1.0/certificates")
      end

      trusted = request.(certfile: laptop.certfile, keyfile: laptop.keyfile)
      assert trusted =~ ~r/\AHTTP\/1.1 200/
      assert trusted =~ "/1.0/certificates/#{Trust.fingerprint(laptop.der)}"

      assert request.(certfile: stranger.certfile, keyfile: stranger.keyfile) =~
               ~r/\AHTTP\/1.1 403/

      assert request.([]) =~ ~r/\AHTTP\/1.1 403/
      assert Macus.Proxy.gateway().host_config.store.state == context.state
    end

    test "native routes answer on the loopback origin with the local identity scope",
         context do
      gateway = serve!(context)
      assert Gateway.identity_scope() == :local
      assert Macus.Proxy.gateway().identity_scope == :local

      {:ok, socket} = tls(gateway.config.port, gateway.certificate.der)
      response = get(socket, "/1.0")
      assert response =~ ~r/\AHTTP\/1.1 200/
      assert response =~ ~s("auth":"untrusted")
      refute response =~ "Gateway identity is unavailable"
    end

    test "an occupied port fails without another listener", context do
      port = free_port()
      {:ok, holder} = :gen_tcp.listen(port, ip: {127, 0, 0, 1})
      configure!(context, %{"port" => port})
      {:ok, gateway} = prepare(context)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _} = start_supervised(Gateway.listener(gateway))
        end)

      assert log =~ "eaddrinuse"
      :gen_tcp.close(holder)
      refute File.exists?(Gateway.metadata_path(context.state))
    end
  end
end
