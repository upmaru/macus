defmodule MacusWeb.MCPTest do
  # The verifier, host and index are global (application environment and a
  # registered index), so run serially.
  use ExUnit.Case, async: false

  alias Macus.MCP.IncusHost
  alias Macus.TestSupport.{AuthFixtures, DexFixtures}
  alias Opsmaru.Incus.Operations.Composite
  alias TamaMCP.Conformance

  @owner_key "owner-key-1"
  @version "2026-07-28"
  @cache Macus.MCP.Cache
  @generic_fixtures [
    "server/discover success",
    "server/discover unsupported version",
    "server/discover header and body disagreement",
    "server/discover rejects protocol session header",
    "tools/call missing tool"
  ]

  setup_all do
    dir = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(dir) end)

    cassette = DexFixtures.cassette!(dir, "opsmaru_incus", "0.2.0", [Composite.openapi()])
    start_supervised!({Tama.Dex.Index, path: :memory, name: Macus.Dex.Index})
    {:ok, _} = Tama.Dex.import(Macus.Dex.Index, cassette.path, sha256: cassette.sha256)
    :ok
  end

  setup do
    previous = Application.fetch_env(:macus, Macus.MCP.Authorization)
    Application.put_env(:macus, Macus.MCP.Authorization, verifier: {__MODULE__, :verify, []})
    on_exit(fn -> restore(Macus.MCP.Authorization, previous) end)
    :ok
  end

  # Test credentials; Macus's token store supplies the real verifier.
  def verify("good-token", _), do: verified(scopes: ["incus.read"])
  def verify("other-owner", _), do: verified(owner_key: "someone-else", scopes: ["incus.read"])
  def verify("expired", _), do: verified(expires_at: DateTime.add(DateTime.utc_now(), -60))
  def verify("no-owner", _), do: verified(owner_key: nil)
  def verify("bad-scopes", _), do: verified(scopes: ["incus.read", "incus.read"])
  def verify("crash", _), do: raise("verifier failure")
  def verify("odd-reply", _), do: :ok
  def verify(_token, _), do: {:error, :unknown}

  def verify(token), do: verify(token, nil)

  defp verified(overrides) do
    {:ok,
     Map.merge(
       %{principal: "owner", owner_key: @owner_key, scopes: [], expires_at: nil},
       Map.new(overrides)
     )}
  end

  describe "conformance" do
    test "the server-independent reference fixtures pass against /mcp" do
      fixtures =
        for fixture <- Conformance.core_fixtures(), fixture["name"] in @generic_fixtures do
          fixture
          |> update_in(["request", "headers"], &authorized_headers/1)
          |> macus_identity()
        end

      assert length(fixtures) == length(@generic_fixtures)
      assert :ok = Conformance.run(&wire_request/1, @cache, fixtures)
    end

    test "discovery advertises tools only, with no task or subscription capability" do
      %{status: 200, body: body} = rpc("server/discover", discover_params())

      assert :ok = Conformance.validate(:discover_response, body, @cache)
      assert body["result"]["capabilities"] == %{"tools" => %{}}

      assert get_in(body, ["result", "_meta", "io.modelcontextprotocol/serverInfo"]) ==
               %{"name" => "macus", "version" => Macus.MCP.Server.version()}
    end

    test "the server version follows the project version" do
      assert Macus.MCP.Server.version() == Mix.Project.config()[:version]
    end
  end

  describe "the tool catalogue" do
    test "lists exactly search and execute, both synchronous" do
      %{status: 200, body: body} = rpc("tools/list", %{})

      assert :ok = Conformance.validate(:list_tools_response, body, @cache)
      tools = body["result"]["tools"]
      assert Enum.map(tools, & &1["name"]) == ["execute", "search"]

      for tool <- tools do
        assert get_in(tool, ["execution", "taskSupport"]) in [nil, "forbidden"]
      end

      by_name = Map.new(tools, &{&1["name"], &1})
      assert by_name["search"]["inputSchema"] == Tama.Dex.MCP.search_tool().input_schema
      assert by_name["execute"]["inputSchema"] == Tama.Dex.MCP.execute_tool().input_schema
    end

    test "no shared operation is advertised as its own tool" do
      %{body: body} = rpc("tools/list", %{})
      names = MapSet.new(body["result"]["tools"], & &1["name"])

      for descriptor <- Composite.all() do
        refute MapSet.member?(names, descriptor.name)
      end

      %{status: 400, body: missing} =
        rpc("tools/call", %{"name" => "incus_server_get", "arguments" => %{}},
          name: "incus_server_get"
        )

      assert missing["error"]["code"] == -32602
    end
  end

  describe "tool calls" do
    test "search runs synchronously with the verified caller's scopes" do
      %{status: 200, body: body} =
        call_tool("search", %{"query" => "instance", "limit" => 20})

      assert :ok = Conformance.validate(:call_tool_response, body, @cache)
      result = body["result"]
      assert result["resultType"] == "complete"
      refute result["isError"]

      results = result["structuredContent"]["results"]
      assert results != []
      assert Enum.all?(results, &(&1["scopes"] == ["incus.read"]))
    end

    test "execute errors are completed tool errors" do
      %{status: 200, body: body} =
        call_tool("execute", %{
          "cassette" => "opsmaru_incus",
          "operation_id" => "incus_instance_delete",
          "input" => %{"name" => "c1", "confirm" => "c1"}
        })

      assert :ok = Conformance.validate(:call_tool_response, body, @cache)
      assert body["result"]["isError"] == true

      assert %{"error" => %{"kind" => "not_found", "dispatched" => false}} =
               body["result"]["structuredContent"]
    end

    test "the verified owner key reaches the Incus operations host" do
      root = DexFixtures.private_root!()
      on_exit(fn -> File.rm_rf!(root) end)

      previous =
        {Application.fetch_env(:macus, :state_dir), Application.fetch_env(:macus, IncusHost)}

      on_exit(fn ->
        restore(:state_dir, elem(previous, 0))
        restore(IncusHost, elem(previous, 1))
      end)

      Application.put_env(:macus, :state_dir, root)

      Application.put_env(:macus, IncusHost,
        owner_uid: File.stat!(root).uid,
        owner_key: @owner_key,
        ready: {Function, :identity, [false]}
      )

      arguments = %{
        "cassette" => "opsmaru_incus",
        "operation_id" => "incus_server_get",
        "input" => %{}
      }

      # The matching owner is bound, then stopped by readiness; another owner
      # is never bound.
      for {token, kind} <- [
            {"good-token", "host_not_ready"},
            {"other-owner", "host_binding_failed"}
          ] do
        %{status: 200, body: body} = call_tool("execute", arguments, token)

        assert %{"operation_error" => %{"error" => %{"kind" => ^kind}}, "dispatched" => true} =
                 body["result"]["structuredContent"]
      end
    end

    test "arguments outside the tool's input schema are rejected before the tool runs" do
      %{status: 400, body: body} = call_tool("search", %{"limit" => 99})
      assert :ok = Conformance.validate(:error_response, body, @cache)
      assert body["error"]["code"] == -32602
    end
  end

  describe "one bounded endpoint" do
    test "only POST /mcp is served" do
      conn = send_conn(:get, "/mcp", "", authorization("good-token"))
      assert conn.status == 405
      assert Plug.Conn.get_resp_header(conn, "allow") == ["POST"]

      for path <- ["/mcp/tools", "/mcp/search", "/mcp/execute"] do
        conn = send_conn(:post, path, "{}", [])
        assert conn.status == 404, path
      end
    end

    test "a body over 1 MiB is refused" do
      body = Jason.encode!(%{"padding" => String.duplicate("a", 1_048_576)})

      conn =
        send_conn(:post, "/mcp", body, mcp_headers("tools/list") ++ authorization("good-token"))

      assert conn.status == 413
    end
  end

  describe "credential verification" do
    test "requests without a valid Macus bearer credential are refused" do
      cases = [
        [],
        [{"authorization", "Basic b3duZXI6c2VjcmV0"}],
        [{"authorization", "Bearer"}],
        [{"authorization", "Bearer has space"}],
        authorization(String.duplicate("a", 4_097)),
        authorization("unknown"),
        authorization("expired"),
        authorization("no-owner"),
        authorization("bad-scopes"),
        authorization("crash"),
        authorization("odd-reply"),
        [{"x-test-token", "ok"}]
      ]

      for headers <- cases do
        conn = send_conn(:post, "/mcp", list_tools_body(), mcp_headers("tools/list") ++ headers)
        assert conn.status == 401, inspect(headers)

        assert Plug.Conn.get_resp_header(conn, "www-authenticate") == [
                 ~s(Bearer error="invalid_token")
               ]

        refute conn.resp_body =~ "verifier failure"
      end
    end

    test "without a configured verifier, nothing is accepted before the token store exists" do
      Application.delete_env(:macus, Macus.MCP.Authorization)
      root = DexFixtures.private_root!()
      on_exit(fn -> File.rm_rf!(root) end)
      {state, uid} = AuthFixtures.state!(root)
      AuthFixtures.configure!(state, uid)
      {token, _record} = AuthFixtures.token!(["incus.read"])

      for credential <- ["good-token", token] do
        conn =
          send_conn(
            :post,
            "/mcp",
            list_tools_body(),
            mcp_headers("tools/list") ++ authorization(credential)
          )

        assert conn.status == 401
      end
    end

    test "the token is case-insensitively a Bearer credential" do
      conn =
        send_conn(
          :post,
          "/mcp",
          list_tools_body(),
          mcp_headers("tools/list") ++ [{"authorization", "bearer good-token"}]
        )

      assert conn.status == 200
    end
  end

  describe "the Macus token store" do
    setup do
      Application.delete_env(:macus, Macus.MCP.Authorization)
      root = DexFixtures.private_root!()
      on_exit(fn -> File.rm_rf!(root) end)
      {state, uid} = AuthFixtures.state!(root)
      AuthFixtures.configure!(state, uid)

      previous = Application.fetch_env(:macus, IncusHost)
      on_exit(fn -> restore(IncusHost, previous) end)

      # Readiness is checked only once a call is bound to the backend; this
      # one reports each check and keeps the backend unreachable.
      Application.put_env(:macus, IncusHost,
        owner_uid: uid,
        owner_key: Macus.Auth.owner_key(uid),
        ready: {__MODULE__, :backend_reached, [self()]}
      )

      %{state: state}
    end

    test "is the default verifier for /mcp", %{state: state} do
      {token, record} = AuthFixtures.token!(["incus.read"], principal: "laptop")
      AuthFixtures.store!(state, [record])

      %{status: 200, body: body} = rpc("tools/list", %{}, token: token)
      assert Enum.map(body["result"]["tools"], & &1["name"]) == ["execute", "search"]

      %{status: 200, body: body} =
        call_tool("search", %{"query" => "instance", "limit" => 5}, token)

      assert Enum.all?(
               body["result"]["structuredContent"]["results"],
               &(&1["scopes"] == ["incus.read"])
             )
    end

    test "a store-verified owner is bound to the Incus host", %{state: state} do
      {token, record} = AuthFixtures.token!(["incus.read"])
      AuthFixtures.store!(state, [record])

      %{status: 200, body: body} = call_tool("execute", server_get(), token)

      assert %{"operation_error" => %{"error" => %{"kind" => "host_not_ready"}}} =
               body["result"]["structuredContent"]

      assert_received :backend_reached
    end

    test "refused credentials and missing scopes never reach the backend", %{state: state} do
      {valid, valid_record} = AuthFixtures.token!(["incus.read"])
      {revoked, revoked_record} = AuthFixtures.token!(["incus.read"])
      {expired, expired_record} = AuthFixtures.token!(["incus.read"])
      {native, native_record} = AuthFixtures.token!(["incus.read"])
      {runtime_only, runtime_record} = AuthFixtures.token!(["runtime.read"])
      {unknown, _} = AuthFixtures.token!(["incus.read"])
      {:ok, id, _} = Macus.Auth.Token.parse(valid)
      {:ok, _, other_secret} = Macus.Auth.Token.parse(unknown)

      AuthFixtures.store!(state, [
        valid_record,
        %{revoked_record | "revoked_at" => "2026-01-01T00:00:00Z"},
        %{expired_record | "expires_at" => "2020-01-01T00:00:00Z"},
        %{native_record | "scopes" => ["incus.read", "incus.native.read"]},
        runtime_record
      ])

      for credential <- [revoked, expired, native, unknown, "macus.#{id}.#{other_secret}"] do
        conn =
          send_conn(
            :post,
            "/mcp",
            Jason.encode!(%{
              "jsonrpc" => "2.0",
              "id" => "call-1",
              "method" => "tools/call",
              "params" => with_meta(%{"name" => "execute", "arguments" => server_get()})
            }),
            mcp_headers("tools/call", "execute") ++ authorization(credential)
          )

        assert conn.status == 401, credential

        assert Plug.Conn.get_resp_header(conn, "www-authenticate") == [
                 ~s(Bearer error="invalid_token")
               ]
      end

      # Verified, but without incus.read.
      %{status: 200, body: body} = call_tool("execute", server_get(), runtime_only)
      assert body["result"]["isError"] == true

      refute_received :backend_reached
    end
  end

  def backend_reached(pid) do
    send(pid, :backend_reached)
    false
  end

  defp server_get,
    do: %{"cassette" => "opsmaru_incus", "operation_id" => "incus_server_get", "input" => %{}}

  # Wire helpers

  defp rpc(method, params, opts \\ []) do
    token = Keyword.get(opts, :token, "good-token")
    name = Keyword.get(opts, :name)

    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => "req-1",
        "method" => method,
        "params" => with_meta(params)
      })

    headers = mcp_headers(method, name) ++ authorization(token)
    conn = send_conn(:post, "/mcp", body, headers)
    %{status: conn.status, body: Jason.decode!(conn.resp_body)}
  end

  defp call_tool(name, arguments, token \\ "good-token") do
    rpc("tools/call", %{"name" => name, "arguments" => arguments}, name: name, token: token)
  end

  defp with_meta(params) do
    Map.put_new(params, "_meta", %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{},
      "io.modelcontextprotocol/clientInfo" => %{"name" => "macus-test", "version" => "1.0.0"}
    })
  end

  defp discover_params, do: %{}

  defp list_tools_body do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => "list-1",
      "method" => "tools/list",
      "params" => with_meta(%{})
    })
  end

  defp mcp_headers(method, name \\ nil) do
    [
      {"mcp-protocol-version", @version},
      {"mcp-method", method},
      {"content-type", "application/json"},
      {"accept", "application/json, text/event-stream"}
    ] ++ if(name, do: [{"mcp-name", name}], else: [])
  end

  defp authorization(token), do: [{"authorization", "Bearer " <> token}]

  defp send_conn(method, path, body, headers) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(method, path, body), fn {name, value}, conn ->
        Plug.Conn.put_req_header(conn, name, value)
      end)

    MacusWeb.Endpoint.call(conn, MacusWeb.Endpoint.init([]))
  end

  # Conformance callback: a fixture request in, a normalized response out.
  defp wire_request(%{"headers" => headers, "body" => body}) do
    headers = Enum.map(headers, fn [name, value] -> {name, value} end)
    conn = send_conn(:post, "/mcp", Jason.encode!(body), headers)
    %{status: conn.status, headers: conn.resp_headers, body: Jason.decode!(conn.resp_body)}
  end

  defp authorized_headers(headers) do
    Enum.reject(headers, fn [name, _] -> name == "x-test-token" end) ++
      [["authorization", "Bearer good-token"]]
  end

  defp macus_identity(%{"name" => "server/discover success"} = fixture) do
    fixture
    |> put_in(
      ["expected", "body", "result", "_meta", "io.modelcontextprotocol/serverInfo"],
      %{"name" => "macus", "version" => Macus.MCP.Server.version()}
    )
    |> put_in(["expected", "body", "result", "instructions"], Macus.MCP.Server.instructions())
  end

  defp macus_identity(fixture), do: fixture

  defp restore(key, {:ok, value}), do: Application.put_env(:macus, key, value)
  defp restore(key, :error), do: Application.delete_env(:macus, key)
end
