defmodule Macus.Proxy.IdentityTrustTest do
  # Gateway configuration, the trust-store process and the admission are global.
  use ExUnit.Case, async: false

  alias Macus.Proxy.{Host, Trust}
  alias Macus.TestSupport.{AuthFixtures, DexFixtures, HTTPFixture, TLSIdentity}
  alias Opsmaru.Incus.Gateway.Identity

  @origin "https://macus.example.net:8443"
  @addresses ["macus.example.net:8443", "203.0.113.7:8443"]
  @extensions ["certificate_update", "instances", "file_delete", "guest_only_extension"]

  setup do
    root = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {state, uid} = AuthFixtures.state!(root)
    AuthFixtures.configure!(state, uid)
    certs = Path.join(root, "certs")
    File.mkdir!(certs)
    File.chmod!(certs, 0o700)

    gateway = TLSIdentity.self_signed(certs, "gateway", "macus.example.net")
    guest = TLSIdentity.self_signed(certs, "guest", "incus-guest")
    admin = TLSIdentity.self_signed(certs, "admin")
    other = TLSIdentity.self_signed(certs, "other")
    gateway_file = Path.join([state, "server", "gateway.crt"])
    File.write!(gateway_file, gateway.pem)
    File.chmod!(gateway_file, 0o644)

    test = self()

    backend =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(state, "incus.sock"),
         handler: fn request ->
           send(test, {:backend, request.method, request.target})
           guest_response(guest.pem)
         end}
      )

    previous = Application.fetch_env(:macus, Macus.Proxy)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:macus, Macus.Proxy, value)
        :error -> Application.delete_env(:macus, Macus.Proxy)
      end
    end)

    configure(uid, gateway_file)
    store = %{state: %Macus.Configuration{state_dir: state}, uid: uid}
    trust!(store, [admin])

    %{
      state: state,
      uid: uid,
      store: store,
      backend: backend,
      gateway: gateway,
      guest: guest,
      admin: admin,
      other: other,
      gateway_file: gateway_file
    }
  end

  defp configure(uid, gateway_file, overrides \\ []) do
    Application.put_env(
      :macus,
      Macus.Proxy,
      Keyword.merge(
        [
          owner_uid: uid,
          owner_key: Macus.Auth.owner_key(uid),
          identity: [
            origin: @origin,
            addresses: @addresses,
            certificate_file: gateway_file,
            api_extensions: @extensions
          ]
        ],
        overrides
      )
    )
  end

  defp trust!(store, identities) do
    now = DateTime.utc_now()
    entries = for %{der: der} <- identities, do: Trust.entry(der, "fixture", "", now)
    path = Trust.path(store.state)
    File.write!(path, Jason.encode!(%{"schema_version" => 1, "certificates" => entries}))
    File.chmod!(path, 0o600)
    path
  end

  defp guest_response(guest_pem) do
    %{
      status: 200,
      body: %{
        "type" => "sync",
        "status" => "Success",
        "status_code" => 200,
        "metadata" => %{
          "api_extensions" => @extensions ++ ["certificate_token"],
          "api_status" => "stable",
          "api_version" => "1.0",
          "auth" => "trusted",
          "public" => false,
          "auth_methods" => ["tls"],
          "config" => %{},
          "environment" => %{
            "addresses" => ["10.0.2.15:8443", "[fd42::1]:8443"],
            "certificate" => guest_pem,
            "server_name" => "incus-guest",
            "server_version" => "7.0"
          }
        }
      }
    }
  end

  defp request(method, path, opts \\ []) do
    body = if opts[:body], do: Jason.encode!(opts[:body]), else: ""

    conn =
      Plug.Test.conn(method, path, body)
      |> Plug.Test.put_peer_data(%{
        address: {198, 51, 100, 9},
        port: 50_000,
        ssl_cert: opts[:certificate]
      })

    conn =
      Enum.reduce(opts[:headers] || [], conn, fn {name, value}, conn ->
        Plug.Conn.put_req_header(conn, name, value)
      end)

    conn =
      if body != "",
        do:
          conn
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> Plug.Conn.put_req_header("content-length", Integer.to_string(byte_size(body))),
        else: conn

    conn = MacusWeb.Endpoint.call(conn, MacusWeb.Endpoint.init([]))
    {conn.status, Jason.decode!(conn.resp_body), conn}
  end

  defp supported(extensions),
    do: Enum.filter(extensions, &(&1 in Identity.supported_extensions()))

  describe "anonymous identity" do
    test "GET / and /1.0 are synthetic and never reach the guest", context do
      assert {200, %{"metadata" => ["/1.0"], "type" => "sync"}, _} = request(:get, "/")

      for certificate <- [nil, context.other.der, context.guest.der] do
        {200, body, _} = request(:get, "/1.0", certificate: certificate)

        assert body["metadata"] == %{
                 "api_version" => "1.0",
                 "api_status" => "stable",
                 "auth" => "untrusted",
                 "public" => false,
                 "auth_methods" => ["tls"],
                 "api_extensions" => supported(@extensions)
               }
      end

      refute_received {:backend, _, _}
    end

    test "discovery fails closed without a usable gateway identity", context do
      configure(context.uid, Path.join(context.state, "missing.crt"))
      assert {503, _, _} = request(:get, "/1.0")

      File.chmod!(context.gateway_file, 0o666)
      configure(context.uid, context.gateway_file)
      assert {503, _, _} = request(:get, "/1.0")

      Application.delete_env(:macus, Macus.Proxy)
      assert {503, _, _} = request(:get, "/")
      refute_received {:backend, _, _}
    end

    test "only explicit public addresses are accepted as identity", context do
      for addresses <- [["10.0.2.15:8443"], ["localhost:8443"], ["192.168.64.2:8443"]] do
        Application.put_env(
          :macus,
          Macus.Proxy,
          put_in(
            Application.get_env(:macus, Macus.Proxy),
            [:identity, :addresses],
            addresses
          )
        )

        assert {503, _, _} = request(:get, "/1.0", certificate: context.admin.der)
      end

      refute_received {:backend, _, _}
    end
  end

  describe "gateway trust, not guest trust" do
    test "untrusted, guest-trusted and bearer callers never reach the guest", context do
      for {certificate, headers} <- [
            {nil, []},
            {context.other.der, []},
            {context.guest.der, []},
            {nil, [{"authorization", "Bearer macus.0123456789abcdef.secret"}]}
          ] do
        assert {403, _, _} =
                 request(:get, "/1.0/instances", certificate: certificate, headers: headers)

        assert {403, _, _} = request(:get, "/1.0/certificates", certificate: certificate)

        assert {403, _, _} =
                 request(:post, "/1.0/certificates",
                   certificate: certificate,
                   body: %{"certificate" => "", "trust_token" => "guest-token"}
                 )
      end

      refute_received {:backend, _, _}
      assert {:ok, [%{"fingerprint" => fingerprint}]} = Trust.entries(context.store)
      assert fingerprint == Trust.fingerprint(context.admin.der)
    end

    test "unauthorized WebSocket and raw upgrades are refused before backend access", context do
      for {path, upgrade} <- [
            {"/1.0/events", "websocket"},
            {"/1.0/operations/abc/websocket?secret=guess", "websocket"},
            {"/1.0/instances/c1/sftp", "sftp"},
            {"/1.0/instances/c1/nbd", "nbd"}
          ],
          certificate <- [nil, context.other.der, context.guest.der] do
        headers = [
          {"connection", "Upgrade"},
          {"upgrade", upgrade},
          {"sec-websocket-version", "13"},
          {"sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ=="}
        ]

        assert {403, _, _} = request(:get, path, certificate: certificate, headers: headers)
      end

      refute_received {:backend, _, _}
    end

    test "an authenticated /1.0 presents the gateway identity, not the guest's", context do
      {200, body, _} = request(:get, "/1.0", certificate: context.admin.der)
      assert_received {:backend, "GET", "/1.0"}

      environment = body["metadata"]["environment"]
      assert environment["certificate"] == Trust.pem(context.gateway.der)
      assert environment["addresses"] == @addresses
      assert environment["server_name"] == "incus-guest"
      assert body["metadata"]["api_extensions"] == supported(@extensions)
      refute inspect(body) =~ "10.0.2.15"
      refute inspect(body) =~ "fd42::1"
      refute inspect(body) =~ String.slice(context.guest.pem, 40, 40)
    end

    test "a removed or expired certificate is refused on the next request", context do
      assert {200, _, _} = request(:get, "/1.0/certificates", certificate: context.admin.der)

      configure(context.uid, context.gateway_file,
        clock: fn -> DateTime.add(DateTime.utc_now(), 3 * 86_400) end
      )

      assert {403, _, _} = request(:get, "/1.0/certificates", certificate: context.admin.der)

      configure(context.uid, context.gateway_file)
      trust!(context.store, [context.other])
      assert {403, _, _} = request(:get, "/1.0/certificates", certificate: context.admin.der)
      assert {200, _, _} = request(:get, "/1.0/certificates", certificate: context.other.der)
    end

    test "an unsafe or malformed trust store trusts nothing and is never rewritten", context do
      path = Trust.path(context.store.state)

      for {contents, mode} <- [
            {File.read!(path), 0o644},
            {"not json", 0o600},
            {Jason.encode!(%{"schema_version" => 2, "certificates" => []}), 0o600},
            {Jason.encode!(%{
               "schema_version" => 1,
               "certificates" => [
                 Map.put(
                   Trust.entry(context.admin.der, "x", "", DateTime.utc_now()),
                   "restricted",
                   true
                 )
               ]
             }), 0o600}
          ] do
        File.write!(path, contents)
        File.chmod!(path, mode)

        assert {403, _, _} = request(:get, "/1.0/certificates", certificate: context.admin.der)

        assert {403, _, _} =
                 request(:post, "/1.0/certificates",
                   certificate: context.admin.der,
                   body: %{"certificate" => context.other.pem}
                 )

        assert File.read!(path) == contents
      end

      refute_received {:backend, _, _}
    end

    test "the grant is rechecked against the current store", context do
      request = %Opsmaru.Incus.Gateway.Request{
        protocol: :http,
        method: "GET",
        path: "/1.0/instances",
        query: "",
        peer: %{address: {198, 51, 100, 9}, port: 1, certificate: context.admin.der}
      }

      config = Macus.Proxy.gateway().host_config
      assert {:ok, grant} = Host.authorize(request, config)
      assert Host.valid?(request, grant, config)

      trust!(context.store, [])
      refute Host.valid?(request, grant, config)
      assert Host.authorize(request, config) == {:error, :unauthenticated}
    end
  end

  describe "native certificate trust API" do
    test "list, get, create, update and delete use native shapes", context do
      admin = Trust.fingerprint(context.admin.der)
      other = Trust.fingerprint(context.other.der)
      as_admin = [certificate: context.admin.der]

      {200, %{"metadata" => urls}, _} = request(:get, "/1.0/certificates", as_admin)
      assert urls == ["/1.0/certificates/#{admin}"]

      {200, %{"metadata" => [object]}, _} =
        request(:get, "/1.0/certificates?recursion=1", as_admin)

      assert object == %{
               "name" => "fixture",
               "type" => "client",
               "restricted" => false,
               "projects" => [],
               "certificate" => Trust.pem(context.admin.der),
               "description" => "",
               "fingerprint" => admin
             }

      assert {400, _, _} = request(:get, "/1.0/certificates?filter=name+eq+x", as_admin)

      # Create from base64 DER, as `incus config trust add-certificate` sends.
      {200, body, conn} =
        request(
          :post,
          "/1.0/certificates",
          as_admin ++
            [
              body: %{
                "certificate" => Base.encode64(context.other.der),
                "name" => "laptop",
                "type" => "client",
                "description" => "second client"
              }
            ]
        )

      assert body["type"] == "sync"
      assert Plug.Conn.get_resp_header(conn, "location") == ["/1.0/certificates/#{other}"]

      # The same certificate again, or the caller's own, conflicts.
      assert {409, _, _} =
               request(:post, "/1.0/certificates",
                 certificate: context.admin.der,
                 body: %{"certificate" => context.other.pem}
               )

      assert {409, _, _} =
               request(:post, "/1.0/certificates",
                 certificate: context.admin.der,
                 body: %{"certificate" => ""}
               )

      {200, %{"metadata" => created}, conn} =
        request(:get, "/1.0/certificates/#{other}", as_admin)

      assert created["name"] == "laptop"
      assert created["description"] == "second client"
      [etag] = Plug.Conn.get_resp_header(conn, "etag")
      assert etag == Host.etag(created)

      # A stale precondition fails; the current one updates.
      assert {412, _, _} =
               request(:put, "/1.0/certificates/#{other}",
                 certificate: context.admin.der,
                 headers: [{"if-match", ~s("stale")}],
                 body: %{"name" => "renamed", "type" => "client", "certificate" => ""}
               )

      assert {200, _, _} =
               request(:put, "/1.0/certificates/#{other}",
                 certificate: context.admin.der,
                 headers: [{"if-match", etag}],
                 body: %{"name" => "renamed", "type" => "client", "description" => "kept"}
               )

      {200, %{"metadata" => renamed}, _} = request(:get, "/1.0/certificates/#{other}", as_admin)
      assert renamed["name"] == "renamed"
      assert renamed["description"] == "kept"

      assert {400, _, _} =
               request(:put, "/1.0/certificates/#{other}",
                 certificate: context.admin.der,
                 body: %{"name" => "x", "type" => "metrics"}
               )

      # The new client is trusted, and deleting it ends that trust.
      assert {200, _, _} = request(:get, "/1.0/certificates", certificate: context.other.der)
      assert {200, _, _} = request(:delete, "/1.0/certificates/#{other}", as_admin)
      assert {404, _, _} = request(:get, "/1.0/certificates/#{other}", as_admin)
      assert {404, _, _} = request(:delete, "/1.0/certificates/#{other}", as_admin)
      assert {403, _, _} = request(:get, "/1.0/certificates", certificate: context.other.der)

      refute_received {:backend, _, _}
    end

    test "restricted, project-scoped, token and non-client requests are refused", context do
      for body <- [
            %{"certificate" => context.other.pem, "restricted" => true},
            %{"certificate" => context.other.pem, "projects" => ["default"]},
            %{"certificate" => context.other.pem, "type" => "metrics"},
            %{"token" => true, "name" => "laptop"},
            %{"certificate" => "not a certificate"},
            %{"certificate" => context.other.pem, "unknown" => true}
          ] do
        assert {400, _, _} =
                 request(:post, "/1.0/certificates", certificate: context.admin.der, body: body)
      end

      assert {:ok, [_admin]} = Trust.entries(context.store)
      refute_received {:backend, _, _}
    end

    test "changes keep other entries and unknown fields", context do
      path = Trust.path(context.store.state)
      document = Jason.decode!(File.read!(path))

      document =
        document
        |> Map.put("comment", "kept")
        |> update_in(["certificates", Access.at(0)], &Map.put(&1, "note", "kept"))

      File.write!(path, Jason.encode!(document))

      assert {200, _, _} =
               request(:post, "/1.0/certificates",
                 certificate: context.admin.der,
                 body: %{"certificate" => context.other.pem}
               )

      stored = Jason.decode!(File.read!(path))
      assert stored["comment"] == "kept"
      assert hd(stored["certificates"])["note"] == "kept"
      assert length(stored["certificates"]) == 2
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      assert Path.wildcard(Path.join(Path.dirname(path), ".trusted-certificates.*")) == []
    end
  end
end
