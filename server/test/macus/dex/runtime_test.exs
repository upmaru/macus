defmodule Macus.Dex.RuntimeTest do
  # The index is registered under Macus.Dex.Index and the executor reads the
  # application environment, so run serially.
  use ExUnit.Case, async: false

  alias Macus.Dex.{RuntimeDocument, RuntimeExecutor}
  alias Macus.TestSupport.HTTPFixture

  @owner_key "owner-key-1"
  @all_scopes ["runtime.read", "runtime.write", "runtime.delete"]
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
    "appliance_manifest_path" => "/appliance/manifest.json",
    "seed_path" => "/appliance/seed.iso",
    "nested_virtualization" => true,
    "shares" => [%{"name" => "workspace", "path" => "/Users/me/project", "read_only" => true}],
    "readiness_timeout_seconds" => 600,
    "shutdown_timeout_seconds" => 60
  }

  setup_all do
    start_supervised!({Tama.Dex.Index, path: :memory, name: Macus.Dex.Index})
    {:ok, _} = Tama.Dex.load(Macus.Dex.Index, RuntimeDocument.document(), cassette: "macus")
    :ok
  end

  setup do
    root = Path.join("/private/tmp", "mc-rt-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    {:ok, script} = Agent.start_link(fn -> %{} end)

    previous =
      {Application.fetch_env(:macus, :state_dir), Application.fetch_env(:macus, RuntimeExecutor)}

    Application.put_env(:macus, :state_dir, root)

    Application.put_env(:macus, RuntimeExecutor,
      owner_uid: File.stat!(root).uid,
      owner_key: @owner_key
    )

    on_exit(fn ->
      restore(:state_dir, elem(previous, 0))
      restore(RuntimeExecutor, elem(previous, 1))
      File.rm_rf!(root)
    end)

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "runtime.sock"),
         handler: fn request -> respond(script, request) end}
      )

    %{root: root, fixture: fixture, script: script}
  end

  describe "the runtime document" do
    test "is a valid tama-operations/1 document of macus_runtime_* operations" do
      document = RuntimeDocument.document()
      assert {:ok, profile} = Tama.Dex.Profile.validate(document)
      assert document["x-tama-source"] == "macus"
      assert length(profile.operations) == 12

      assert Enum.all?(
               RuntimeDocument.operation_ids(),
               &String.starts_with?(&1, "macus_runtime_")
             )
    end

    test "scopes, destructive markers, confirmations and preconditions follow the plan" do
      ops = operations()

      reads = ~w(status progress health capabilities config_get)
      writes = ~w(create start stop restart config_update)
      destructive = ~w(force_stop delete)

      for name <- reads, do: assert(ops[name]["x-tama-scopes"] == ["runtime.read"])
      for name <- writes, do: assert(ops[name]["x-tama-scopes"] == ["runtime.write"])

      for name <- destructive do
        assert ops[name]["x-tama-scopes"] == ["runtime.delete"]
        assert ops[name]["x-tama-destructive"] == true
        assert ops[name]["x-tama-confirmation"]["field"] == "confirm"
      end

      for name <- reads ++ writes, do: refute(ops[name]["x-tama-destructive"])

      assert ops["config_update"]["x-macus-requires-state"] == "stopped"
      assert ops["delete"]["x-macus-requires-state"] == "stopped"
      assert ops["delete"]["description"] =~ "stopped"
      assert ops["config_update"]["description"] =~ "stopped"

      for name <- writes ++ destructive do
        assert ops[name]["x-tama-identity"] == ["status", "state"]
        assert ops[name]["x-tama-bounds"]["max_wait_seconds"] == 25
      end

      assert ops["status"]["x-tama-identity"] == ["state"]
    end

    test "is the default macus cassette of the operation index" do
      {:ok, state} = Macus.Configuration.new("/private/tmp/macus-state")

      [%{start: {_module, :start_link, [opts]}}] =
        Macus.Dex.children([enabled: true, owner_uid: 501], state)

      assert {:ok, config} = opts[:config]
      assert config.documents == [Macus.Dex.runtime_document()]
    end
  end

  describe "reads" do
    test "return the native record, with status omitting the private socket path", ctx do
      script(ctx, %{
        {"GET", "/v1/runtime/progress"} =>
          {200,
           %{"state" => "starting", "ready" => false, "operation" => "start", "phase" => "incus"}},
        {"GET", "/v1/runtime/health"} =>
          {200,
           %{
             "protocol_version" => 1,
             "incus_version" => "6.0",
             "api_extensions" => [],
             "kvm" => true
           }},
        {"GET", "/v1/runtime/capabilities"} =>
          {200, %{"platform" => "darwin", "supported" => true}},
        {"GET", "/v1/runtime/config"} => {200, @config}
      })

      assert %{"result" => status} = run!("macus_runtime_status", %{}, ["runtime.read"])
      assert status["state"] == "stopped"
      refute Map.has_key?(status, "incus_socket")

      assert %{"result" => %{"phase" => "incus"}} =
               run!("macus_runtime_progress", %{}, ["runtime.read"])

      assert %{"result" => %{"kvm" => true}} = run!("macus_runtime_health", %{}, ["runtime.read"])

      assert %{"result" => %{"platform" => "darwin"}} =
               run!("macus_runtime_capabilities", %{}, ["runtime.read"])

      assert %{"result" => @config} = run!("macus_runtime_config_get", %{}, ["runtime.read"])

      assert Enum.map(HTTPFixture.requests(ctx.fixture), &{&1.method, &1.target, &1.body}) == [
               {"GET", "/v1/runtime/status", ""},
               {"GET", "/v1/runtime/progress", ""},
               {"GET", "/v1/runtime/health", ""},
               {"GET", "/v1/runtime/capabilities", ""},
               {"GET", "/v1/runtime/config", ""}
             ]
    end

    test "a native error keeps its code and status", ctx do
      script(ctx, %{
        {"GET", "/v1/runtime/health"} =>
          {503, %{"error" => %{"code" => "unavailable", "message" => "Incus is not ready"}}}
      })

      assert %{
               "operation_error" => %{
                 "error" => %{
                   "code" => "unavailable",
                   "http_status" => 503,
                   "message" => "Incus is not ready"
                 }
               },
               "dispatched" => true
             } = run("macus_runtime_health", %{}, ["runtime.read"])
    end
  end

  describe "lifecycle requests match the Swift CLI" do
    test "each operation sends the private API request the Swift client sends", ctx do
      calls = [
        {"macus_runtime_create", @config, ["runtime.write"],
         {"POST", "/v1/runtime/create", @config}},
        {"macus_runtime_start", %{}, ["runtime.write"], {"POST", "/v1/runtime/start", ""}},
        {"macus_runtime_start", %{"remaining_seconds" => 30}, ["runtime.write"],
         {"POST", "/v1/runtime/start", %{"remaining_seconds" => 30}}},
        {"macus_runtime_stop", %{}, ["runtime.write"],
         {"POST", "/v1/runtime/stop", %{"force" => false}}},
        {"macus_runtime_force_stop", %{"confirm" => "force-stop"}, ["runtime.delete"],
         {"POST", "/v1/runtime/stop", %{"force" => true}}},
        {"macus_runtime_restart", %{}, ["runtime.write"], {"POST", "/v1/runtime/restart", ""}},
        {"macus_runtime_config_update", @config, ["runtime.write"],
         {"PUT", "/v1/runtime/config", @config}},
        {"macus_runtime_delete", %{"confirm" => "delete-runtime"}, ["runtime.delete"],
         {"DELETE", "/v1/runtime", %{"confirm" => true}}}
      ]

      for {operation, input, scopes, _request} <- calls do
        assert %{"result" => result} = run!(operation, input, scopes)

        assert %{"status" => "completed", "state" => "stopped", "wait_error" => nil} = result
        refute Map.has_key?(result["runtime"], "incus_socket")
      end

      requests = HTTPFixture.requests(ctx.fixture)
      assert length(requests) == length(calls)

      for {request, {_op, _input, _scopes, {method, target, body}}} <- Enum.zip(requests, calls) do
        assert request.method == method
        assert request.target == target
        assert decoded(request.body) == body
      end
    end

    test "an unmet stopped-state precondition is the native 409", ctx do
      conflict = %{
        "error" => %{
          "code" => "conflict",
          "message" => "Stop the VM before deleting runtime data"
        }
      }

      script(ctx, %{
        {"DELETE", "/v1/runtime"} => {409, conflict},
        {"PUT", "/v1/runtime/config"} => {409, conflict}
      })

      for {operation, input} <- [
            {"macus_runtime_delete", %{"confirm" => "delete-runtime"}},
            {"macus_runtime_config_update", @config}
          ] do
        assert %{
                 "operation_error" => %{"error" => %{"code" => "conflict", "http_status" => 409}},
                 "dispatched" => true
               } = run(operation, input, @all_scopes)
      end
    end

    test "a reply that does not arrive in time is uncertain and not resent", ctx do
      env = Application.get_env(:macus, RuntimeExecutor)
      Application.put_env(:macus, RuntimeExecutor, Keyword.put(env, :mutation_timeout_ms, 200))
      script(ctx, %{{"POST", "/v1/runtime/start"} => :slow})

      assert %{
               "result" => %{
                 "status" => "uncertain",
                 "state" => nil,
                 "runtime" => nil,
                 "wait_error" => "timeout"
               }
             } =
               run!("macus_runtime_start", %{}, ["runtime.write"])

      assert length(HTTPFixture.requests(ctx.fixture)) == 1
    end

    test "a lost reply after the request is sent is uncertain", ctx do
      script(ctx, %{{"POST", "/v1/runtime/restart"} => :lost})

      assert %{"result" => %{"status" => "uncertain", "runtime" => nil}} =
               run!("macus_runtime_restart", %{}, ["runtime.write"])

      assert length(HTTPFixture.requests(ctx.fixture)) == 1
    end
  end

  describe "denial before runtime dispatch" do
    test "destructive operations need their exact confirm token", ctx do
      for {operation, input, kind} <- [
            {"macus_runtime_delete", %{}, "confirmation_required"},
            {"macus_runtime_delete", %{"confirm" => "yes"}, "invalid_input"},
            {"macus_runtime_force_stop", %{"confirm" => "delete-runtime"}, "invalid_input"},
            {"macus_runtime_force_stop", %{}, "confirmation_required"}
          ] do
        assert %{"error" => %{"kind" => ^kind, "dispatched" => false}} =
                 run(operation, input, @all_scopes)
      end

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "operations outside the caller's scopes are not found", ctx do
      for {operation, input, scopes} <- [
            {"macus_runtime_start", %{}, ["runtime.read"]},
            {"macus_runtime_delete", %{"confirm" => "delete-runtime"}, ["runtime.write"]},
            {"macus_runtime_status", %{}, ["incus.read"]}
          ] do
        assert %{"error" => %{"kind" => "not_found", "dispatched" => false}} =
                 run(operation, input, scopes)
      end

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "invalid configuration input never reaches the runtime", ctx do
      for config <- [
            Map.put(@config, "cpu_count", 0),
            Map.delete(@config, "shares"),
            Map.put(@config, "appliance_manifest_path", "relative/manifest.json"),
            Map.put(@config, "incus_socket", "/tmp/other.sock")
          ] do
        assert %{"error" => %{"kind" => "invalid_input", "dispatched" => false}} =
                 run("macus_runtime_create", config, ["runtime.write"])
      end

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "the executor itself refuses an unverified caller, missing scope or bad token", ctx do
      call = fn operation, scopes, context ->
        RuntimeExecutor.execute(
          %Tama.Dex.Call{
            cassette: "macus",
            source: "macus",
            operation_id: operation,
            scopes: scopes,
            context: context
          },
          %{"confirm" => "wrong"}
        )
      end

      cases = [
        {call.(
           "macus_runtime_status",
           ["runtime.read"],
           context(["runtime.read"], "someone-else")
         ), "unauthorized"},
        {call.("macus_runtime_status", ["runtime.read"], %{
           owner_key: @owner_key,
           scopes: ["runtime.read"]
         }), "unauthorized"},
        {call.("macus_runtime_status", ["runtime.read"], context([])), "forbidden"},
        {call.("macus_runtime_status", [], context(["runtime.read"])), "forbidden"},
        {call.("macus_runtime_delete", ["runtime.delete"], context(["runtime.delete"])),
         "confirmation_required"},
        {call.("macus_shell", ["runtime.read"], context(["runtime.read"])), "unknown_operation"}
      ]

      for {result, code} <- cases do
        assert {:error, %{"error" => %{"code" => ^code, "outcome" => "not_dispatched"}}} = result
      end

      Application.delete_env(:macus, RuntimeExecutor)

      assert {:error, %{"error" => %{"code" => "unavailable", "outcome" => "not_dispatched"}}} =
               call.("macus_runtime_status", ["runtime.read"], context(["runtime.read"]))

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "an unsafe or missing runtime socket is never used", ctx do
      socket = Path.join(ctx.root, "runtime.sock")
      File.chmod!(socket, 0o666)

      assert %{
               "operation_error" => %{
                 "error" => %{"code" => "unsafe_socket", "outcome" => "not_dispatched"}
               }
             } =
               run("macus_runtime_stop", %{}, ["runtime.write"])

      File.chmod!(socket, 0o600)
      assert HTTPFixture.requests(ctx.fixture) == []

      stop_supervised!(HTTPFixture)

      assert %{
               "operation_error" => %{
                 "error" => %{"code" => "unavailable", "outcome" => "not_dispatched"}
               }
             } =
               run("macus_runtime_status", %{}, ["runtime.read"])
    end
  end

  # Runs through the execute path: tama-dex checks, then the executor.
  defp run(operation, input, scopes) do
    Macus.MCP.execute(
      %{"cassette" => "macus", "operation_id" => operation, "input" => input},
      context(scopes)
    )
  end

  defp run!(operation, input, scopes) do
    result = run(operation, input, scopes)
    assert %{"cassette" => "macus", "source" => "macus", "operation_id" => ^operation} = result
    result
  end

  defp context(scopes, owner_key \\ @owner_key) do
    %TamaMCP.Context{
      request_id: 1,
      principal: "owner",
      owner_key: owner_key,
      claims: %{},
      scopes: scopes
    }
  end

  defp operations do
    for {"/operations/macus_runtime_" <> name, %{"post" => op}} <-
          RuntimeDocument.document()["paths"],
        into: %{},
        do: {name, op}
  end

  defp script(ctx, responses), do: Agent.update(ctx.script, fn _ -> responses end)

  defp respond(script, request) do
    case Map.get(Agent.get(script, & &1), {request.method, request.target}) do
      nil -> %{status: 200, body: @status}
      :slow -> %{wire_chunks: [{1_000, "HTTP/1.1 200 OK\r\n"}]}
      :lost -> %{raw: ""}
      {status, body} -> %{status: status, body: body}
    end
  end

  defp decoded(""), do: ""
  defp decoded(body), do: Jason.decode!(body)

  defp restore(key, {:ok, value}), do: Application.put_env(:macus, key, value)
  defp restore(key, :error), do: Application.delete_env(:macus, key)
end
