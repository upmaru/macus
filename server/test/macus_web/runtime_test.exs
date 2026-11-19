defmodule MacusWeb.RuntimeTest do
  # The bearer configuration, stream registry and running-gateway record are
  # global.
  use ExUnit.Case, async: false

  alias Macus.TestSupport.{AuthFixtures, DexFixtures, HTTPFixture}

  @status %{
    "api_version" => 1,
    "state" => "stopped",
    "incus_socket" => "/private/state/incus.sock",
    "last_error" => nil,
    "uptime_seconds" => 0
  }
  @config %{
    "schema_version" => 1,
    "cpu_count" => 4,
    "memory_mib" => 4096,
    "data_disk_gib" => 32,
    "appliance_manifest_path" => "/absolute/appliance/manifest.json",
    "seed_path" => "/absolute/appliance/seed.iso",
    "nested_virtualization" => true,
    "shares" => [%{"name" => "workspace", "path" => "/absolute/project", "read_only" => true}],
    "readiness_timeout_seconds" => 600,
    "shutdown_timeout_seconds" => 60
  }

  setup do
    root = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    {state, uid} = AuthFixtures.state!(root)
    AuthFixtures.configure!(state, uid)

    tokens =
      for {name, scopes} <- [
            read: ["runtime.read"],
            write: ["runtime.read", "runtime.write"],
            admin: ["runtime.read", "runtime.write", "runtime.delete"],
            incus: ["incus.read", "incus.write"]
          ],
          into: %{} do
        {token, record} = AuthFixtures.token!(scopes, principal: Atom.to_string(name))
        {name, {token, record}}
      end

    AuthFixtures.store!(state, Enum.map(tokens, fn {_, {_, record}} -> record end))
    %{state: state, uid: uid, tokens: Map.new(tokens, fn {name, {token, _}} -> {name, token} end)}
  end

  defp swift!(context, handler) do
    test = self()

    start_supervised!(
      {HTTPFixture,
       transport: :gen_tcp,
       path: Path.join(context.state, "runtime.sock"),
       handler: fn request ->
         send(test, {:swift, request.method, request.target, request.body})
         handler.(request)
       end}
    )
  end

  defp ok(body \\ @status), do: fn _ -> %{status: 200, body: body} end

  defp call(method, path, token, body \\ "") do
    conn = Plug.Test.conn(method, path, body)

    conn =
      if token,
        do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token),
        else: conn

    conn = MacusWeb.Endpoint.call(conn, MacusWeb.Endpoint.init([]))
    {conn.status, Jason.decode!(conn.resp_body), conn}
  end

  test "public routes map to the private /v1/runtime routes", context do
    swift!(context, ok())
    %{read: read, write: write, admin: admin} = context.tokens
    config = Jason.encode!(@config)

    for {method, path, token, body, private_method, private_path, private_body} <- [
          {:get, "/runtime/status", read, "", "GET", "/v1/runtime/status", ""},
          {:get, "/runtime/capabilities", read, "", "GET", "/v1/runtime/capabilities", ""},
          {:get, "/runtime/health", read, "", "GET", "/v1/runtime/health", ""},
          {:get, "/runtime/config", read, "", "GET", "/v1/runtime/config", ""},
          {:get, "/runtime/progress", read, "", "GET", "/v1/runtime/progress", ""},
          {:post, "/runtime/create", write, config, "POST", "/v1/runtime/create", config},
          {:put, "/runtime/config", write, config, "PUT", "/v1/runtime/config", config},
          {:post, "/runtime/start", write, "", "POST", "/v1/runtime/start", ""},
          {:post, "/runtime/start", write, ~s({"remaining_seconds":29}), "POST",
           "/v1/runtime/start", ~s({"remaining_seconds":29})},
          {:post, "/runtime/stop", write, "", "POST", "/v1/runtime/stop", ~s({"force":false})},
          {:post, "/runtime/stop", write, ~s({"force":false}), "POST", "/v1/runtime/stop",
           ~s({"force":false})},
          {:post, "/runtime/stop", admin, ~s({"force":true,"confirm":"force-stop"}), "POST",
           "/v1/runtime/stop", ~s({"force":true})},
          {:post, "/runtime/restart", write, "", "POST", "/v1/runtime/restart", ""},
          {:delete, "/runtime", admin, ~s({"confirm":"delete-runtime"}), "DELETE", "/v1/runtime",
           ~s({"confirm":true})}
        ] do
      assert {200, _, _} = call(method, path, token, body)
      assert_receive {:swift, ^private_method, ^private_path, ^private_body}
    end
  end

  test "status loses the private socket path and gains public readiness", context do
    swift!(context, ok())

    assert {200, status, _} = call(:get, "/runtime/status", context.tokens.read)
    refute Map.has_key?(status, "incus_socket")
    refute inspect(status) =~ "incus.sock"
    assert status["state"] == "stopped"
    assert status["server_ready"] == true
    assert status["runtime_ready"] == false
    assert status["server_endpoint"] == nil

    # Mutations answering with a status object are projected the same way.
    assert {200, started, _} = call(:post, "/runtime/start", context.tokens.write)
    refute Map.has_key?(started, "incus_socket")
  end

  test "status names the running gateway and separates its readiness", context do
    swift!(context, ok(%{@status | "state" => "ready"}))

    {:ok, state} = Macus.Configuration.new(context.state)

    Macus.Gateway.put_current(%Macus.Gateway{
      state: state,
      uid: context.uid,
      config: %{url: "https://127.0.0.1:8443"},
      certificate: %{fingerprint: String.duplicate("ab", 32)},
      build: %{}
    })

    on_exit(&Macus.Gateway.clear_current/0)

    assert {200, status, _} = call(:get, "/runtime/status", context.tokens.read)

    endpoint = %{
      "url" => "https://127.0.0.1:8443",
      "certificate_fingerprint" => String.duplicate("ab", 32)
    }

    assert status["server_endpoint"] == endpoint
    assert status["incus_endpoint"] == endpoint
    assert status["runtime_ready"] == true
  end

  test "credentials and scopes are checked before any private request", context do
    swift!(context, ok())
    %{read: read, write: write, incus: incus} = context.tokens

    for {method, path, token, body, status, code} <- [
          {:get, "/runtime/status", nil, "", 401, "unauthorized"},
          {:get, "/runtime/status", "macus.0000000000000000.#{String.duplicate("a", 43)}", "",
           401, "unauthorized"},
          {:get, "/runtime/status", incus, "", 403, "forbidden"},
          {:post, "/runtime/start", read, "", 403, "forbidden"},
          {:put, "/runtime/config", read, Jason.encode!(@config), 403, "forbidden"},
          {:delete, "/runtime", write, ~s({"confirm":"delete-runtime"}), 403, "forbidden"},
          {:post, "/runtime/stop", write, ~s({"force":true,"confirm":"force-stop"}), 403,
           "forbidden"}
        ] do
      assert {^status, %{"error" => error}, _} = call(method, path, token, body)
      assert error["code"] == code, "#{method} #{path}"
      assert error["outcome"] == "not_dispatched"
    end

    refute_received {:swift, _, _, _}
  end

  test "a revoked or expired credential is refused on its next request", context do
    swift!(context, ok())
    {token, record} = AuthFixtures.token!(["runtime.read"])
    {expired, expired_record} = AuthFixtures.token!(["runtime.read"])

    AuthFixtures.store!(context.state, [
      %{record | "revoked_at" => "2026-01-01T00:00:00Z"},
      %{expired_record | "expires_at" => "2026-01-01T00:00:00Z"}
    ])

    assert {401, _, _} = call(:get, "/runtime/status", token)
    assert {401, _, _} = call(:get, "/runtime/status", expired)
    refute_received {:swift, _, _, _}
  end

  test "unknown paths and methods fail before any private request", context do
    swift!(context, ok())
    read = context.tokens.read

    assert {404, %{"error" => %{"code" => "not_found"}}, _} =
             call(:get, "/runtime/v1/status", read)

    assert {404, _, _} = call(:get, "/runtime/incus.sock", read)
    assert {404, _, _} = call(:get, "/runtime/status/extra", read)
    assert {405, _, conn} = call(:post, "/runtime/status", read)
    assert Plug.Conn.get_resp_header(conn, "allow") == ["GET"]
    assert {405, _, conn} = call(:get, "/runtime", read)
    assert Plug.Conn.get_resp_header(conn, "allow") == ["DELETE"]
    assert {405, _, conn} = call(:delete, "/runtime/config", read)
    assert Plug.Conn.get_resp_header(conn, "allow") == ["GET, PUT"]
    refute_received {:swift, _, _, _}
  end

  test "configuration must be complete and confirmations explicit", context do
    swift!(context, ok())
    %{write: write, admin: admin} = context.tokens

    incomplete = [
      Map.delete(@config, "memory_mib"),
      Map.put(@config, "memory", 4096),
      %{@config | "cpu_count" => "4"},
      %{@config | "nested_virtualization" => "true"},
      %{@config | "seed_path" => 7},
      %{@config | "shares" => [%{"name" => "workspace"}]},
      %{@config | "shares" => [%{"name" => "w", "path" => "/p", "mode" => "rw"}]}
    ]

    for config <- incomplete,
        {method, path} <- [post: "/runtime/create", put: "/runtime/config"] do
      assert {400, %{"error" => error}, _} = call(method, path, write, Jason.encode!(config))
      assert error["code"] == "invalid_configuration"
    end

    assert {400, _, _} = call(:post, "/runtime/create", write, "[]")
    assert {400, _, _} = call(:post, "/runtime/create", write, "{")

    assert {200, _, _} =
             call(
               :post,
               "/runtime/create",
               write,
               Jason.encode!(Map.delete(@config, "seed_path"))
             )

    assert_receive {:swift, "POST", "/v1/runtime/create", _}

    for body <- [
          "",
          ~s({"confirm":true}),
          ~s({"confirm":"yes"}),
          ~s({"confirm":"delete-runtime","x":1})
        ] do
      assert {400, %{"error" => %{"code" => "confirmation_required"}}, _} =
               call(:delete, "/runtime", admin, body)
    end

    assert {400, %{"error" => %{"code" => "confirmation_required"}}, _} =
             call(:post, "/runtime/stop", admin, ~s({"force":true}))

    assert {400, _, _} = call(:post, "/runtime/stop", admin, ~s({"force":"yes"}))
    assert {400, _, _} = call(:post, "/runtime/start", write, ~s({"remaining":5}))
    assert {400, _, _} = call(:post, "/runtime/restart", write, ~s({"now":true}))
    assert {400, _, _} = call(:get, "/runtime/status", context.tokens.read, "{}")
    refute_received {:swift, _, _, _}
  end

  test "Swift errors, conflicts and budgets pass through unchanged", context do
    conflict =
      ~s({"error":{"code":"conflict","message":"A runtime mutation is already in progress"}})

    invalid =
      ~s({"error":{"code":"invalid_request","message":"remaining_seconds must be 1...3600"}})

    swift!(context, fn request ->
      case request.target do
        "/v1/runtime/config" -> %{raw: raw(409, conflict)}
        "/v1/runtime/start" -> %{raw: raw(400, invalid)}
      end
    end)

    assert {409, body, conn} =
             call(:put, "/runtime/config", context.tokens.write, Jason.encode!(@config))

    assert body == Jason.decode!(conflict)
    assert conn.resp_body == conflict

    assert {400, body, _} =
             call(:post, "/runtime/start", context.tokens.write, ~s({"remaining_seconds":0}))

    assert body == Jason.decode!(invalid)
    assert_receive {:swift, "PUT", "/v1/runtime/config", _}
    assert_receive {:swift, "POST", "/v1/runtime/start", ~s({"remaining_seconds":0})}
  end

  test "bodies are bounded here, without a global parser", context do
    swift!(context, ok())
    oversized = ~s({"padding":") <> String.duplicate("a", 1_048_576) <> ~s("})

    assert {413, %{"error" => %{"code" => "payload_too_large"}}, _} =
             call(:post, "/runtime/create", context.tokens.write, oversized)

    refute_received {:swift, _, _, _}
  end

  test "the gateway stays available when the runtime service or guest is not", context do
    # No runtime.sock: the server answers and says the runtime is unavailable.
    assert {503, status, _} = call(:get, "/runtime/status", context.tokens.read)
    assert status["server_ready"] == true
    assert status["runtime_ready"] == false
    assert status["error"]["code"] == "unavailable"
    assert status["error"]["outcome"] == "not_dispatched"

    assert {503, start, _} = call(:post, "/runtime/start", context.tokens.write)
    assert start["error"]["outcome"] == "not_dispatched"
    refute Map.has_key?(start, "server_ready")

    # A stopped guest: status is readable and start is still dispatched.
    swift!(context, ok())

    assert {200, %{"runtime_ready" => false, "state" => "stopped"}, _} =
             call(:get, "/runtime/status", context.tokens.read)

    assert {200, _, _} = call(:post, "/runtime/start", context.tokens.write)
    assert_receive {:swift, "POST", "/v1/runtime/start", ""}
  end

  test "a boot whose Swift connection breaks is sent once; progress passes through", context do
    progress =
      ~s({"api_version":1,"ready":false,"state":"starting","phase":"kernel_transition","expected_reboot":true})

    swift!(context, fn request ->
      case request.target do
        # Swift accepted the boot, then the connection closed without an answer.
        "/v1/runtime/start" -> %{raw: ""}
        "/v1/runtime/progress" -> %{raw: raw(200, progress)}
      end
    end)

    assert {503, start, _} =
             call(:post, "/runtime/start", context.tokens.write, ~s({"remaining_seconds":60}))

    assert start["error"]["outcome"] == "unknown"
    assert_receive {:swift, "POST", "/v1/runtime/start", ~s({"remaining_seconds":60})}
    refute_receive {:swift, "POST", _, _}, 200

    assert {200, _, conn} = call(:get, "/runtime/progress", context.tokens.read)
    assert conn.resp_body == progress
  end

  test "revoking a credential ends its in-flight runtime request", context do
    test = self()

    swift!(context, fn
      %{target: "/v1/runtime/start"} ->
        send(test, :start_reached)
        Process.sleep(:infinity)

      _ ->
        %{status: 200, body: @status}
    end)

    {token, record} = AuthFixtures.token!(["runtime.read", "runtime.write"])
    {other, other_record} = AuthFixtures.token!(["runtime.read"])
    AuthFixtures.store!(context.state, [record, other_record])

    {request, monitor} = spawn_monitor(fn -> call(:post, "/runtime/start", token) end)
    assert_receive :start_reached, 2_000
    assert Macus.Auth.Streams.Watcher.check() == []

    AuthFixtures.store!(context.state, [
      %{record | "revoked_at" => "2026-01-01T00:00:00Z"},
      other_record
    ])

    assert Macus.Auth.Streams.Watcher.check() == [request]
    assert_receive {:DOWN, ^monitor, :process, ^request, {:shutdown, :credential_revoked}}

    assert {401, _, _} = call(:post, "/runtime/start", token)
    assert {200, _, _} = call(:get, "/runtime/status", other)
    assert Macus.Auth.Streams.entries() == []
  end

  describe "docs/api.md" do
    setup do
      text = File.read!(Path.expand("../../../docs/api.md", __DIR__))
      [_, public] = String.split(text, "## Public runtime API\n", parts: 2)
      [public, private] = String.split(public, "## Private runtime API v1\n", parts: 2)
      %{public: public, private: private}
    end

    test "every public route in the table maps, with its scope and body", context do
      swift!(context, ok())

      rows =
        for line <- String.split(context.public, "\n"),
            [_, method, path, private, scope, body] <-
              [
                Regex.run(
                  ~r/^\| (\w+) \| `([^`]+)` \| `(\w+ [^`]+)`.*? \| `([\w.]+)` \| (.+) \|$/,
                  line
                )
              ] do
          {method, path, private, scope, body}
        end

      assert length(rows) == 12

      token = %{
        "runtime.read" => context.tokens.read,
        "runtime.write" => context.tokens.write,
        "runtime.delete" => context.tokens.admin
      }

      lacking = %{
        "runtime.read" => context.tokens.incus,
        "runtime.write" => context.tokens.read,
        "runtime.delete" => context.tokens.write
      }

      for {method, path, private, scope, body} <- rows do
        body =
          cond do
            body == "Complete configuration" -> Jason.encode!(@config)
            String.starts_with?(body, "Empty") -> ""
            match = Regex.run(~r/`(\{[^`]+\})`$/, body) -> List.last(match)
            true -> ""
          end

        verb = method |> String.downcase() |> String.to_atom()
        assert {403, _, _} = call(verb, path, lacking[scope], body), "#{method} #{path}"
        refute_received {:swift, _, _, _}

        assert {200, _, _} = call(verb, path, token[scope], body), "#{method} #{path}"
        [private_method, private_path] = String.split(private, " ", parts: 2)
        assert_receive {:swift, ^private_method, ^private_path, _}, 1_000
      end
    end

    test "the documented status example has the public projection's keys", context do
      [example] =
        Regex.run(~r/```json\n(.+?)```/s, context.public, capture: :all_but_first)

      swift!(context, ok(%{@status | "state" => "ready"}))
      {:ok, state} = Macus.Configuration.new(context.state)

      Macus.Gateway.put_current(%Macus.Gateway{
        state: state,
        uid: context.uid,
        config: %{url: "https://127.0.0.1:8443"},
        certificate: %{fingerprint: String.duplicate("ab", 32)},
        build: %{}
      })

      on_exit(&Macus.Gateway.clear_current/0)

      assert {200, status, _} = call(:get, "/runtime/status", context.tokens.read)
      example = Jason.decode!(example)
      assert Enum.sort(Map.keys(status)) == Enum.sort(Map.keys(example))
      assert Map.keys(status["server_endpoint"]) == Map.keys(example["server_endpoint"])
      assert status["server_ready"] == example["server_ready"]
      assert status["runtime_ready"] == example["runtime_ready"]
    end

    test "a running VM's configuration conflict passes through with no implicit restart",
         context do
      # The documented configuration with the documented share added.
      [config] =
        Regex.run(~r/```json\n(\{\n  "schema_version".+?)```/s, context.private,
          capture: :all_but_first
        )

      [share] =
        Regex.run(~r/A share is `(\{[^`]+\})`/, context.private, capture: :all_but_first)

      config =
        config |> Jason.decode!() |> Map.put("shares", [Jason.decode!(share)]) |> Jason.encode!()

      conflict =
        ~s({"error":{"code":"conflict","message":"Configuration requires a stopped VM"}})

      assert context.public =~ "Configuration requires a stopped VM"
      swift!(context, fn _ -> %{raw: raw(409, conflict)} end)

      assert {409, _, conn} = call(:put, "/runtime/config", context.tokens.write, config)
      assert conn.resp_body == conflict
      assert_receive {:swift, "PUT", "/v1/runtime/config", ^config}
      refute_receive {:swift, _, _, _}, 200
    end
  end

  defp raw(status, body) do
    reason = %{200 => "OK", 400 => "Bad Request", 409 => "Conflict"}[status]

    "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
      body
  end
end
