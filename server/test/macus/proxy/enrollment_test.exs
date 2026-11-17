defmodule Macus.Proxy.EnrollmentTest do
  # Gateway configuration and the trust and enrollment processes are global.
  use ExUnit.Case, async: false

  alias Macus.Proxy.{Enrollment, Trust}

  alias Macus.TestSupport.{
    AuthFixtures,
    DexFixtures,
    EnrollmentFixtures,
    HTTPFixture,
    TLSIdentity
  }

  @origin "https://macus.example.net:8443"
  @addresses ["macus.example.net:8443"]

  setup do
    root = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {state, uid} = AuthFixtures.state!(root)
    AuthFixtures.configure!(state, uid)
    certs = Path.join(root, "certs")
    File.mkdir!(certs)
    File.chmod!(certs, 0o700)

    gateway = TLSIdentity.self_signed(certs, "gateway", "macus.example.net")
    admin = TLSIdentity.self_signed(certs, "admin")
    laptop = TLSIdentity.self_signed(certs, "laptop")
    phone = TLSIdentity.self_signed(certs, "phone")
    gateway_file = Path.join([state, "server", "gateway.crt"])
    File.write!(gateway_file, gateway.pem)
    File.chmod!(gateway_file, 0o644)
    test = self()

    start_supervised!(
      {HTTPFixture,
       transport: :gen_tcp,
       path: Path.join(state, "incus.sock"),
       handler: fn request ->
         send(test, {:backend, request.method, request.target})
         %{status: 500, body: %{"type" => "error", "error" => "unexpected", "error_code" => 500}}
       end}
    )

    previous = Application.fetch_env(:macus, Macus.Proxy)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:macus, Macus.Proxy, value)
        :error -> Application.delete_env(:macus, Macus.Proxy)
      end
    end)

    store = %{state: %Macus.Configuration{state_dir: state}, uid: uid}
    path = Trust.path(store.state)
    entry = Trust.entry(admin.der, "admin", "", DateTime.utc_now())
    File.write!(path, Jason.encode!(%{"schema_version" => 1, "certificates" => [entry]}))
    File.chmod!(path, 0o600)

    context = %{
      uid: uid,
      store: store,
      gateway: gateway,
      gateway_file: gateway_file,
      admin: admin,
      laptop: laptop,
      phone: phone
    }

    configure(context)
    context
  end

  defp configure(context, overrides \\ []) do
    Application.put_env(
      :macus,
      Macus.Proxy,
      Keyword.merge(
        [
          owner_uid: context.uid,
          owner_key: Macus.Auth.owner_key(context.uid),
          identity: [
            origin: @origin,
            addresses: @addresses,
            certificate_file: context.gateway_file,
            api_extensions: ["certificate_update"]
          ]
        ],
        overrides
      )
    )
  end

  defp issue!(context, name, opts \\ []),
    do: EnrollmentFixtures.issue!(context.store, name, context.gateway.der, @addresses, opts)

  defp enroll(identity, token, extra \\ %{}) do
    request(:post, "/1.0/certificates",
      certificate: identity && identity.der,
      body: Map.merge(%{"trust_token" => token}, extra)
    )
  end

  defp request(method, path, opts) do
    body = if opts[:body], do: Jason.encode!(opts[:body]), else: ""

    conn =
      Plug.Test.conn(method, path, body)
      |> Plug.Test.put_peer_data(%{
        address: {198, 51, 100, 9},
        port: 50_000,
        ssl_cert: opts[:certificate]
      })

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

  defp fingerprints(store) do
    {:ok, entries} = Trust.entries(store)
    Enum.map(entries, & &1["fingerprint"])
  end

  defp redeemed(store) do
    {:ok, redemptions} = Enrollment.redemptions(store)
    Enum.map(redemptions, &{&1["id"], &1["fingerprint"]})
  end

  test "a valid token enrolls the presented certificate exactly once", context do
    issued = issue!(context, "laptop")
    laptop = Trust.fingerprint(context.laptop.der)

    # Only the token and peer certificate count: name, certificate and
    # description in the request cannot override the token.
    assert {200, response, conn} =
             enroll(context.laptop, issued.token, %{
               "name" => "override",
               "certificate" => context.phone.pem,
               "description" => "ignored"
             })

    assert response["type"] == "sync"
    assert response["status_code"] == 200
    assert Plug.Conn.get_resp_header(conn, "location") == ["/1.0/certificates/#{laptop}"]

    {:ok, entries} = Trust.entries(context.store)
    assert [_admin, entry] = entries
    assert entry["fingerprint"] == laptop
    assert entry["name"] == "laptop"
    assert entry["description"] == ""
    assert entry["type"] == "client"
    assert redeemed(context.store) == [{issued.id, laptop}]

    redemptions = Enrollment.redemptions_path(context.store.state)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(redemptions)
    assert Bitwise.band(mode, 0o777) == 0o600
    refute File.read!(redemptions) =~ issued.secret

    # The enrolled certificate is now a trusted client.
    assert {200, %{"metadata" => listed}, _} =
             request(:get, "/1.0/certificates", certificate: context.laptop.der)

    assert length(listed) == 2
    refute_received {:backend, _, _}
  end

  test "a consumed token is refused for every later client", context do
    issued = issue!(context, "laptop")
    assert {200, _, _} = enroll(context.laptop, issued.token)

    assert {403, _, _} = enroll(context.phone, issued.token)

    # The enrolled laptop is now trusted, so it takes the authenticated
    # create path, which ignores the token, as natively.
    assert {409, _, _} = enroll(context.laptop, issued.token)

    assert fingerprints(context.store) == [
             Trust.fingerprint(context.admin.der),
             Trust.fingerprint(context.laptop.der)
           ]

    assert {403, _, _} = request(:get, "/1.0/certificates", certificate: context.phone.der)
    refute_received {:backend, _, _}
  end

  test "an expired token is consumed and refused", context do
    issued = issue!(context, "laptop", expires_at: DateTime.add(DateTime.utc_now(), 60))
    later = DateTime.add(DateTime.utc_now(), 120)
    configure(context, clock: fn -> later end)

    assert {403, _, _} = enroll(context.laptop, issued.token)
    assert redeemed(context.store) == [{issued.id, Trust.fingerprint(context.laptop.der)}]

    # Consumed, so it stays refused even once the clock is back in range.
    configure(context)
    assert {403, _, _} = enroll(context.laptop, issued.token)
    assert fingerprints(context.store) == [Trust.fingerprint(context.admin.der)]
    refute_received {:backend, _, _}
  end

  test "unknown, revoked, malformed and wrong-secret tokens enroll nothing", context do
    revoked =
      issue!(context, "revoked",
        fields: %{"revoked_at" => DateTime.to_iso8601(DateTime.utc_now())}
      )

    valid = issue!(context, "valid")
    other = issue!(context, "other")

    wrong_secret =
      valid.token
      |> Base.decode64!()
      |> Jason.decode!()
      |> Map.put("secret", other.secret <> "0")
      |> Jason.encode!()
      |> Base.encode64()

    missing_name =
      valid.token
      |> Base.decode64!()
      |> Jason.decode!()
      |> Map.put("client_name", "")
      |> Jason.encode!()
      |> Base.encode64()

    for token <- [
          revoked.token,
          wrong_secret,
          missing_name,
          "",
          "not base64!",
          Base.encode64("[]"),
          valid.token <> "\n",
          String.duplicate("A", 9_000)
        ] do
      assert {403, _, _} = enroll(context.laptop, token)
    end

    assert {403, _, _} = enroll(context.laptop, nil)
    assert {403, _, _} = enroll(context.laptop, 42)
    assert fingerprints(context.store) == [Trust.fingerprint(context.admin.der)]
    assert redeemed(context.store) == []

    # The valid token was not consumed by any of those attempts.
    assert {200, _, _} = enroll(context.laptop, valid.token)
    refute_received {:backend, _, _}
  end

  test "enrollment requires a current client certificate and keeps the token", context do
    issued = issue!(context, "laptop")

    assert {403, _, _} = enroll(nil, issued.token)

    future = DateTime.add(DateTime.utc_now(), 10 * 86_400)
    configure(context, clock: fn -> future end)
    assert {400, _, _} = enroll(context.laptop, issued.token)

    configure(context)
    assert redeemed(context.store) == []
    assert {200, _, _} = enroll(context.laptop, issued.token)
    refute_received {:backend, _, _}
  end

  test "a trusted client's token is ignored and stays unconsumed", context do
    issued = issue!(context, "admin-again")
    assert {409, _, _} = enroll(context.admin, issued.token)
    assert fingerprints(context.store) == [Trust.fingerprint(context.admin.der)]
    assert redeemed(context.store) == []
    assert {200, _, _} = enroll(context.laptop, issued.token)
    refute_received {:backend, _, _}
  end

  test "a certificate trusted meanwhile consumes the token and gets 409", context do
    issued = issue!(context, "admin-again")

    assert {:error, 409} =
             Enrollment.redeem(
               context.store,
               issued.secret,
               context.admin.der,
               DateTime.utc_now()
             )

    assert fingerprints(context.store) == [Trust.fingerprint(context.admin.der)]
    assert [{_, _}] = redeemed(context.store)
    assert {403, _, _} = enroll(context.laptop, issued.token)
  end

  test "restricted, project and token-issuing requests are refused before redemption",
       context do
    issued = issue!(context, "laptop")

    for extra <- [
          %{"restricted" => true},
          %{"projects" => ["default"]},
          %{"type" => "metrics"},
          %{"token" => true},
          %{"unknown" => "field"}
        ] do
      assert {400, _, _} = enroll(context.laptop, issued.token, extra)
    end

    assert redeemed(context.store) == []
    assert {200, _, _} = enroll(context.laptop, issued.token)
    refute_received {:backend, _, _}
  end

  test "restricted or project token records make the store unusable", context do
    issue!(context, "laptop")
    restricted = issue!(context, "restricted", fields: %{"restricted" => true})

    assert {503, _, _} = enroll(context.laptop, restricted.token)
    assert {:error, 503} = Enrollment.tokens(context.store)

    File.rm!(Enrollment.tokens_path(context.store.state))
    projects = issue!(context, "projects", fields: %{"projects" => ["default"]})
    assert {503, _, _} = enroll(context.laptop, projects.token)
    assert fingerprints(context.store) == [Trust.fingerprint(context.admin.der)]
    refute_received {:backend, _, _}
  end

  test "unsafe or malformed stores enroll nothing and are never rewritten", context do
    issued = issue!(context, "laptop")
    tokens = Enrollment.tokens_path(context.store.state)
    redemptions = Enrollment.redemptions_path(context.store.state)

    File.chmod!(tokens, 0o644)
    assert {503, _, _} = enroll(context.laptop, issued.token)
    File.chmod!(tokens, 0o600)

    File.write!(redemptions, ~s({"schema_version": 1, "redemptions": [{"id": "bad"}]}))
    File.chmod!(redemptions, 0o600)
    assert {503, _, _} = enroll(context.laptop, issued.token)
    assert File.read!(redemptions) =~ ~s("bad")

    File.rm!(redemptions)
    File.ln_s!(tokens, redemptions)
    assert {503, _, _} = enroll(context.laptop, issued.token)
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(redemptions)
    File.rm!(redemptions)

    assert fingerprints(context.store) == [Trust.fingerprint(context.admin.der)]
    assert {200, _, _} = enroll(context.laptop, issued.token)
    refute_received {:backend, _, _}
  end

  test "concurrent redemptions of one token enroll exactly one certificate", context do
    issued = issue!(context, "laptop")
    identities = [context.laptop, context.phone] ++ for(_ <- 1..6, do: context.laptop)

    statuses =
      identities
      |> Enum.map(fn identity -> Task.async(fn -> enroll(identity, issued.token) end) end)
      |> Enum.map(fn task -> task |> Task.await() |> elem(0) end)

    assert Enum.count(statuses, &(&1 == 200)) == 1
    assert Enum.all?(statuses, &(&1 in [200, 403]))
    assert length(fingerprints(context.store)) == 2
    assert [_] = redeemed(context.store)
  end

  test "redemption records are pruned to issued tokens", context do
    first = issue!(context, "first")
    assert {200, _, _} = enroll(context.laptop, first.token)

    # The owner removes the first token record; the next redemption drops its record.
    File.write!(
      Enrollment.tokens_path(context.store.state),
      Jason.encode!(%{"schema_version" => 1, "tokens" => []})
    )

    second = issue!(context, "second")
    assert {200, _, _} = enroll(context.phone, second.token)
    assert redeemed(context.store) == [{second.id, Trust.fingerprint(context.phone.der)}]
  end

  test "decode/1 accepts native tokens only" do
    # Encoded as the Go client's api.CertificateAddToken.String() does.
    native =
      Base.encode64(
        ~s({"client_name":"user@host","fingerprint":"57bb0ff4340b5bb28517e062023101adf788c37846dc8b619eb2c3cb4ef29436","addresses":["10.98.30.229:8443"],"secret":"2b2284d44db32675923fe0d2020477e0e9be11801ff70c435e032b97028c35cd","expires_at":"2021-03-23T17:38:37.753398689-04:00"})
      )

    assert {:ok, token} = Enrollment.decode(native)
    assert token.client_name == "user@host"
    assert token.addresses == ["10.98.30.229:8443"]
    assert token.secret == "2b2284d44db32675923fe0d2020477e0e9be11801ff70c435e032b97028c35cd"

    for field <- ~w(client_name fingerprint secret) do
      broken = native |> Base.decode64!() |> Jason.decode!() |> Map.delete(field)
      assert Enrollment.decode(broken |> Jason.encode!() |> Base.encode64()) == :error
    end

    no_addresses =
      native |> Base.decode64!() |> Jason.decode!() |> Map.put("addresses", []) |> Jason.encode!()

    assert Enrollment.decode(Base.encode64(no_addresses)) == :error
    assert Enrollment.decode(Base.url_encode64("{}", padding: false)) == :error
  end
end
