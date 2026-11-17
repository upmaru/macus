defmodule Macus.Proxy.OfficialClientTrustTest do
  # Drives the pinned official Incus Go client against the Macus endpoint on a
  # TLS 1.3 Cowboy listener, as a standard remote client would connect.
  use ExUnit.Case, async: false

  alias Macus.Proxy.Trust

  alias Macus.TestSupport.{
    AuthFixtures,
    DexFixtures,
    EnrollmentFixtures,
    HTTPFixture,
    TLSIdentity
  }

  alias Opsmaru.Incus.Gateway.Identity

  @driver Path.expand("../../../../.integration/incus-reference-driver", __DIR__)
  @reference_dir Path.expand("../../reference", __DIR__)
  @origin "https://macus.example.net:8443"
  @addresses ["macus.example.net:8443"]
  @extensions ["certificate_update", "instances", "file_delete", "guest_only_extension"]

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
    {state, uid} = AuthFixtures.state!(root)
    AuthFixtures.configure!(state, uid)
    certs = Path.join(root, "certs")
    File.mkdir!(certs)
    File.chmod!(certs, 0o700)

    server = TLSIdentity.generate(certs, "server", "localhost")
    guest = TLSIdentity.self_signed(certs, "guest", "incus-guest")
    admin = TLSIdentity.self_signed(certs, "admin")
    laptop = TLSIdentity.self_signed(certs, "laptop")
    phone = TLSIdentity.self_signed(certs, "phone")
    test = self()

    start_supervised!(
      {HTTPFixture,
       transport: :gen_tcp,
       path: Path.join(state, "incus.sock"),
       handler: fn request ->
         send(test, {:backend, request.method, request.target})
         guest_server(guest.pem)
       end}
    )

    previous = Application.fetch_env(:macus, Macus.Proxy)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:macus, Macus.Proxy, value)
        :error -> Application.delete_env(:macus, Macus.Proxy)
      end
    end)

    Application.put_env(:macus, Macus.Proxy,
      owner_uid: uid,
      owner_key: Macus.Auth.owner_key(uid),
      identity: [
        origin: @origin,
        addresses: @addresses,
        certificate_file: server.certfile,
        api_extensions: @extensions
      ]
    )

    store = %{state: %Macus.Configuration{state_dir: state}, uid: uid}
    path = Trust.path(store.state)
    entry = Trust.entry(admin.der, "admin", "", DateTime.utc_now())
    File.write!(path, Jason.encode!(%{"schema_version" => 1, "certificates" => [entry]}))
    File.chmod!(path, 0o600)

    port = listen!(server)

    %{
      root: root,
      port: port,
      server: server,
      guest: guest,
      admin: admin,
      laptop: laptop,
      phone: phone,
      store: store
    }
  end

  # The production listener (task 3.2) collects any client certificate;
  # trust is decided by the gateway trust store, not by a CA.
  defp listen!(server) do
    ref = {:macus_trust_fixture, make_ref()}

    dispatch =
      :cowboy_router.compile([{:_, [{:_, Plug.Cowboy.Handler, {MacusWeb.Endpoint, []}}]}])

    {:ok, _} =
      :cowboy.start_tls(
        ref,
        %{
          num_acceptors: 2,
          max_connections: 16,
          socket_opts: [
            ip: {127, 0, 0, 1},
            port: 0,
            certfile: String.to_charlist(server.certfile),
            keyfile: String.to_charlist(server.keyfile),
            # OTP requires some CA list with verify_peer; the verify_fun
            # below accepts self-signed client certificates regardless. Like
            # Incus, advertise no acceptable CAs: Go clients otherwise send
            # no certificate whose issuer is not listed.
            cacertfile: String.to_charlist(server.cafile),
            certificate_authorities: false,
            verify: :verify_peer,
            fail_if_no_peer_cert: false,
            verify_fun: {&collect_peer/3, nil},
            versions: [:"tlsv1.3"],
            alpn_preferred_protocols: ["http/1.1"]
          ]
        },
        %{env: %{dispatch: dispatch}}
      )

    on_exit(fn -> :cowboy.stop_listener(ref) end)
    :ranch.get_port(ref)
  end

  defp collect_peer(_certificate, {:bad_cert, _reason}, state), do: {:valid, state}
  defp collect_peer(_certificate, {:extension, _}, state), do: {:unknown, state}
  defp collect_peer(_certificate, _event, state), do: {:valid, state}

  defp guest_server(guest_pem) do
    %{
      status: 200,
      body: %{
        "type" => "sync",
        "status" => "Success",
        "status_code" => 200,
        "metadata" => %{
          "api_extensions" => @extensions,
          "api_status" => "stable",
          "api_version" => "1.0",
          "auth" => "trusted",
          "public" => false,
          "auth_methods" => ["tls"],
          "config" => %{},
          "environment" => %{
            "addresses" => ["10.0.2.15:8443"],
            "certificate" => guest_pem,
            "server_name" => "incus-guest",
            "server_version" => "7.0"
          }
        }
      }
    }
  end

  defp client(context, identity, action, fields \\ %{}) do
    input =
      Map.merge(
        %{
          "url" => "https://localhost:#{context.port}",
          "server_cert" => File.read!(context.server.certfile),
          "tls_ca" => File.read!(context.server.cafile),
          "action" => action
        },
        fields
      )

    input =
      case identity do
        nil ->
          input

        %{certfile: certfile, keyfile: keyfile} ->
          Map.merge(input, %{
            "client_cert" => File.read!(certfile),
            "client_key" => File.read!(keyfile)
          })
      end

    path = Path.join(context.root, "client-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(input))
    File.chmod!(path, 0o600)
    {output, status} = System.cmd(@driver, [path], stderr_to_stdout: true)
    File.rm!(path)
    assert status == 0, output
    Jason.decode!(output)
  end

  defp supported, do: Enum.filter(@extensions, &(&1 in Identity.supported_extensions()))

  test "untrusted clients see only the synthetic gateway identity", context do
    for identity <- [nil, context.laptop, context.guest] do
      %{"server" => server} = client(context, identity, "server")
      assert server["auth"] == "untrusted"
      assert server["api_extensions"] == supported()
      assert server["environment"]["certificate"] == ""
      assert server["environment"]["addresses"] == nil
    end

    refute_received {:backend, _, _}
  end

  test "a trusted client sees the gateway certificate and public addresses", context do
    %{"server" => server} = client(context, context.admin, "server")
    assert server["auth"] == "trusted"
    assert server["environment"]["certificate"] == Trust.pem(context.server.der)
    assert server["environment"]["addresses"] == @addresses
    assert server["api_extensions"] == supported()
    assert_received {:backend, "GET", "/1.0"}
  end

  test "the official client manages gateway trust with native shapes", context do
    admin = Trust.fingerprint(context.admin.der)
    laptop = Trust.fingerprint(context.laptop.der)

    %{"certificates" => [listed]} = client(context, context.admin, "certificates")
    assert listed["fingerprint"] == admin
    assert listed["type"] == "client"
    assert listed["restricted"] == false
    assert listed["certificate"] == Trust.pem(context.admin.der)

    # Untrusted self-enrollment without a token is refused.
    refused =
      client(context, context.laptop, "create", %{"certificate" => "", "name" => "laptop"})

    assert refused["error_status"] == 403
    assert {:ok, [_]} = Trust.entries(context.store)

    # The owner-admin adds the laptop as `incus config trust add-certificate` does.
    created =
      client(context, context.admin, "create", %{
        "certificate" => Base.encode64(context.laptop.der),
        "name" => "laptop"
      })

    refute created["error"]

    %{"fingerprints" => fingerprints} = client(context, context.admin, "fingerprints")
    assert Enum.sort(fingerprints) == Enum.sort([admin, laptop])

    %{"certificate" => got, "etag" => etag} =
      client(context, context.admin, "certificate", %{"fingerprint" => laptop})

    assert got["name"] == "laptop"
    assert etag != ""

    renamed =
      client(context, context.admin, "rename", %{"fingerprint" => laptop, "name" => "work-laptop"})

    refute renamed["error"]

    %{"certificate" => got} =
      client(context, context.admin, "certificate", %{"fingerprint" => laptop})

    assert got["name"] == "work-laptop"

    # The laptop is now trusted by the gateway, until it is removed.
    %{"certificates" => certificates} = client(context, context.laptop, "certificates")
    assert length(certificates) == 2
    refute client(context, context.admin, "delete", %{"fingerprint" => laptop})["error"]
    assert client(context, context.laptop, "certificates")["error_status"] == 403

    for message <- flush_backend() do
      assert message == {"GET", "/1.0"}
    end
  end

  defp flush_backend do
    receive do
      {:backend, method, target} -> [{method, target} | flush_backend()]
    after
      0 -> []
    end
  end

  # The pinned official client sends `"type": ""` (and the other zero-valued
  # CertificatePut fields) beside `trust_token`. Native Incus ignores every
  # field but the token when redeeming it; the shared gateway's claims check
  # in opsmaru_incus 0.2.0 refuses the empty type with 400 before the host
  # callback. Verified passing with that check accepting "" for token
  # requests; enable with the opsmaru_incus release that does.
  @tag skip: "needs opsmaru_incus to accept the official client's empty type with trust_token"
  test "the official client enrolls once with a token, as incus remote add does", context do
    issued =
      EnrollmentFixtures.issue!(context.store, "laptop", context.server.der, @addresses)

    enrolled = client(context, context.laptop, "enroll", %{"token" => issued.token})
    refute enrolled["error"], inspect(enrolled)
    assert enrolled["fingerprint_match"] == true
    assert enrolled["client_name"] == "laptop"
    assert enrolled["addresses"] == @addresses

    # Enrollment answered without any backend request.
    refute_received {:backend, _, _}

    {:ok, [_admin, entry]} = Trust.entries(context.store)
    assert entry["fingerprint"] == Trust.fingerprint(context.laptop.der)
    assert entry["name"] == "laptop"

    # The enrolled client now uses standard authenticated requests.
    %{"server" => server} = client(context, context.laptop, "server")
    assert server["auth"] == "trusted"
    %{"certificates" => certificates} = client(context, context.laptop, "certificates")
    assert length(certificates) == 2

    # Replaying the consumed token from another client is refused.
    flush_backend()
    replay = client(context, context.phone, "enroll", %{"token" => issued.token})
    assert replay["error_status"] == 403
    assert client(context, context.phone, "certificates")["error_status"] == 403
    assert {:ok, [_, _]} = Trust.entries(context.store)
    refute_received {:backend, _, _}
  end

  # The pinned official client sends `"type": ""` (and the other zero-valued
  # CertificatePut fields) beside `trust_token`. Native Incus ignores every
  # field but the token when redeeming it; the shared gateway's claims check
  # in opsmaru_incus 0.2.0 refuses the empty type with 400 before the host
  # callback. Verified passing with that check accepting "" for token
  # requests; enable with the opsmaru_incus release that does.
  @tag skip: "needs opsmaru_incus to accept the official client's empty type with trust_token"
  test "the official client is refused an expired token", context do
    issued =
      EnrollmentFixtures.issue!(context.store, "phone", context.server.der, @addresses,
        expires_at: DateTime.add(DateTime.utc_now(), 60)
      )

    later = DateTime.add(DateTime.utc_now(), 120)

    Application.put_env(
      :macus,
      Macus.Proxy,
      Keyword.put(Application.get_env(:macus, Macus.Proxy), :clock, fn -> later end)
    )

    expired = client(context, context.phone, "enroll", %{"token" => issued.token})
    assert expired["error_status"] == 403, inspect(expired)
    assert {:ok, [_admin]} = Trust.entries(context.store)
    refute_received {:backend, _, _}
  end
end
