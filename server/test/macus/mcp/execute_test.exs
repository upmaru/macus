defmodule Macus.MCP.ExecuteTest do
  # The index is registered under Macus.Dex.Index and the host reads the
  # application environment, so run serially.
  use ExUnit.Case, async: false

  alias Macus.MCP
  alias Macus.MCP.{DexTool, IncusHost, Tools.Execute}
  alias Macus.TestSupport.{DexFixtures, HTTPFixture}
  alias Opsmaru.Incus.Operations.{Composite, Native}

  @owner_key "owner-key-1"
  @server %{"api_version" => "1.0", "api_extensions" => [], "auth" => "trusted"}

  setup_all do
    dir = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(dir) end)

    cassette =
      DexFixtures.cassette!(dir, "opsmaru_incus", "0.2.0", [Composite.openapi(), Native.openapi()])

    start_supervised!({Tama.Dex.Index, path: :memory, name: Macus.Dex.Index})

    {:ok, %{cassette: "opsmaru_incus"}} =
      Tama.Dex.import(Macus.Dex.Index, cassette.path, sha256: cassette.sha256)

    macus = DexFixtures.document("macus", ["macus_fixture_status"])
    {:ok, _} = Tama.Dex.load(Macus.Dex.Index, macus, cassette: "macus")

    native =
      Enum.find_value(Enum.sort(Native.openapi()["paths"]), fn {_path, item} ->
        op = item |> Map.values() |> hd()
        if op["x-tama-scopes"] == ["incus.native.read"], do: op["operationId"]
      end)

    %{native_operation: native}
  end

  setup do
    root = Path.join("/private/tmp", "mc-exec-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    {:ok, ready} = Agent.start_link(fn -> true end)
    {:ok, responses} = Agent.start_link(fn -> %{} end)

    previous =
      {Application.fetch_env(:macus, :state_dir), Application.fetch_env(:macus, IncusHost)}

    Application.put_env(:macus, :state_dir, root)

    Application.put_env(:macus, IncusHost,
      owner_uid: File.stat!(root).uid,
      owner_key: @owner_key,
      ready: {__MODULE__, :ready?, [ready]}
    )

    on_exit(fn ->
      restore(:state_dir, elem(previous, 0))
      restore(IncusHost, elem(previous, 1))
      File.rm_rf!(root)
    end)

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "incus.sock"),
         handler: fn request -> respond_to(responses, request) end}
      )

    %{fixture: fixture, ready: ready, responses: responses}
  end

  def ready?(agent), do: Agent.get(agent, & &1)

  describe "the tool module" do
    test "advertises the tama-dex execute definition with no tool-level scope" do
      definition = Execute.definition()
      tool = Tama.Dex.MCP.execute_tool()

      assert definition["title"] == tool.title
      assert definition["inputSchema"] == tool.input_schema
      assert definition["outputSchema"] == tool.output_schema
      assert Execute.scopes() == []
      assert Execute.task_policy() == :disabled

      for {name, arity} <- [definition: 0, scopes: 0, task_policy: 0, call: 2] do
        assert function_exported?(Execute, name, arity)
      end
    end

    test "registers the shared Incus and Macus runtime executors, and no native one" do
      assert MCP.executors() == %{
               "opsmaru_incus" => Macus.Dex.IncusExecutor,
               "macus" => Macus.Dex.RuntimeExecutor
             }
    end
  end

  describe "running shared operations" do
    test "a read returns its result with cassette, operation and source", ctx do
      structured = call!(%{"operation_id" => "incus_server_get"}, ["incus.read"], :success)

      assert %{
               "cassette" => "opsmaru_incus",
               "operation_id" => "incus_server_get",
               "source" => "opsmaru_incus",
               "result" => %{"item" => %{"api_version" => "1.0"}}
             } = structured

      assert [%{method: "GET", target: "/1.0"} | _] = HTTPFixture.requests(ctx.fixture)
    end

    test "a mutation still running after its wait reports acceptance with identity", ctx do
      Agent.update(ctx.responses, fn _ -> %{wait_status: {"Running", 103}} end)

      structured =
        call!(
          %{"operation_id" => "incus_instance_state_update", "input" => start_input()},
          ["incus.write"],
          :success
        )

      assert %{"status" => "running", "operation_id" => "op-1"} = structured["result"]
      assert puts(ctx.fixture) == 1
    end

    test "a completed mutation reports completion", ctx do
      Agent.update(ctx.responses, fn _ -> %{wait_status: {"Success", 200}} end)

      structured =
        call!(
          %{"operation_id" => "incus_instance_state_update", "input" => start_input()},
          ["incus.write"],
          :success
        )

      assert %{"status" => "completed", "operation_id" => "op-1"} = structured["result"]
    end

    test "a lost mutation response is uncertain and never resent", ctx do
      Agent.update(ctx.responses, fn _ -> %{lose_put: true} end)

      structured =
        call!(
          %{"operation_id" => "incus_instance_state_update", "input" => start_input()},
          ["incus.write"],
          :success
        )

      assert structured["result"]["status"] == "uncertain"
      assert puts(ctx.fixture) == 1
    end
  end

  describe "denials before dispatch" do
    test "unknown cassettes and operations hidden by scopes are not found", ctx do
      for {arguments, scopes} <- [
            {%{"cassette" => "other", "operation_id" => "incus_server_get"}, ["incus.read"]},
            {%{"operation_id" => "incus_host_shell"}, ["incus.read"]},
            {%{"operation_id" => "incus_instance_delete", "input" => delete_input()},
             ["incus.read"]}
          ] do
        assert %{"error" => %{"kind" => "not_found", "dispatched" => false}} =
                 call!(arguments, scopes, :tool_error)
      end

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "invalid tool arguments and operation input fail undispatched", ctx do
      assert %{"error" => %{"kind" => "invalid_arguments", "dispatched" => false}} =
               execute(%{"cassette" => "opsmaru_incus", "operation_id" => "incus_server_get"}, [
                 "incus.read"
               ])

      assert %{"error" => %{"kind" => "invalid_input", "dispatched" => false}} =
               call!(
                 %{"operation_id" => "incus_server_get", "input" => %{"socket" => "/tmp/x"}},
                 ["incus.read"],
                 :tool_error
               )

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "a destructive operation needs its confirmation field", ctx do
      input = Map.delete(delete_input(), "confirm")

      assert %{
               "error" => %{
                 "kind" => "confirmation_required",
                 "dispatched" => false,
                 "details" => %{"field" => "confirm"}
               }
             } =
               call!(
                 %{"operation_id" => "incus_instance_delete", "input" => input},
                 ["incus.delete"],
                 :tool_error
               )

      assert HTTPFixture.requests(ctx.fixture) == []
    end
  end

  describe "operation errors" do
    test "a shared operation's own error is a dispatched tool error", ctx do
      Agent.update(ctx.ready, fn _ -> false end)

      assert %{
               "cassette" => "opsmaru_incus",
               "operation_id" => "incus_server_get",
               "source" => "opsmaru_incus",
               "operation_error" => %{"error" => %{"kind" => "host_not_ready"}},
               "dispatched" => true
             } = call!(%{"operation_id" => "incus_server_get"}, ["incus.read"], :tool_error)

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "a mismatched confirmation is refused by the operation itself", ctx do
      input = Map.put(delete_input(), "confirm", "not-the-name")

      assert %{
               "operation_error" => %{"error" => %{"kind" => "confirmation_required"}},
               "dispatched" => true
             } =
               call!(
                 %{"operation_id" => "incus_instance_delete", "input" => input},
                 ["incus.delete"],
                 :tool_error
               )

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "dispatch failures and invalid output are dispatched tool errors" do
      for {executor, kind} <- [
            {__MODULE__.RaisingExecutor, "dispatch_failed"},
            {__MODULE__.MalformedExecutor, "invalid_output"}
          ] do
        structured =
          Tama.Dex.MCP.handle_execute(
            Macus.Dex.Index,
            %{"cassette" => "macus", "operation_id" => "macus_fixture_status", "input" => %{}},
            context(["fixture.read"]),
            %{"macus" => executor}
          )

        assert %{"error" => %{"kind" => ^kind, "dispatched" => true}} = structured
        assert {:ok, %TamaMCP.Response{is_error: true}} = DexTool.respond(structured)
      end
    end
  end

  describe "sources without an executor" do
    test "native operations stay hidden even from a caller holding native scopes", ctx do
      native = ctx.native_operation
      scopes = ["incus.read" | Native.scopes()]

      assert %{"error" => %{"kind" => "not_found", "dispatched" => false}} =
               call!(%{"operation_id" => native}, scopes, :tool_error)

      # Without the scope filter tama-dex would find it, and still refuse it.
      assert %{"error" => %{"kind" => "no_executor", "dispatched" => false}} =
               Tama.Dex.MCP.handle_execute(
                 Macus.Dex.Index,
                 %{"cassette" => "opsmaru_incus", "operation_id" => native, "input" => %{}},
                 context(scopes),
                 MCP.executors()
               )

      assert MCP.caller(context(scopes)).scopes == ["incus.read"]
      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "the runtime executor refuses an operation the runtime document does not define" do
      assert %{
               "operation_error" => %{"error" => %{"code" => "unknown_operation"}},
               "dispatched" => true
             } =
               execute(
                 %{
                   "cassette" => "macus",
                   "operation_id" => "macus_fixture_status",
                   "input" => %{}
                 },
                 ["fixture.read"]
               )
    end

    test "an absent index is not ready and dispatches nothing" do
      arguments = %{
        "cassette" => "opsmaru_incus",
        "operation_id" => "incus_server_get",
        "input" => %{}
      }

      assert %{"error" => %{"kind" => "not_ready", "dispatched" => false}} =
               MCP.execute(arguments, context(["incus.read"]), :macus_absent_index)
    end
  end

  defmodule RaisingExecutor do
    @behaviour Tama.Dex.Executor
    @impl true
    def execute(_call, _input), do: raise("executor failure")
  end

  defmodule MalformedExecutor do
    @behaviour Tama.Dex.Executor
    @impl true
    def execute(_call, _input), do: :not_a_result
  end

  # Calls the tool module and checks the response kind and output schema.
  defp call!(arguments, scopes, expected) do
    arguments = Map.merge(%{"cassette" => "opsmaru_incus", "input" => %{}}, arguments)
    {:ok, response} = Execute.call(arguments, context(scopes))

    assert response.is_error == (expected == :tool_error)
    assert [%{"type" => "text", "text" => text}] = Enum.map(response.content, &stringify/1)
    assert Jason.decode!(text) == response.structured_content

    {:ok, schema} = JSONSchex.compile(Execute.definition()["outputSchema"], draft: "draft2020_12")
    assert :ok = JSONSchex.validate(schema, response.structured_content)
    response.structured_content
  end

  defp execute(arguments, scopes), do: MCP.execute(arguments, context(scopes))

  defp context(scopes) do
    %TamaMCP.Context{
      request_id: 1,
      principal: "owner",
      owner_key: @owner_key,
      claims: %{},
      scopes: scopes
    }
  end

  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp start_input, do: %{"name" => "c1", "action" => "start", "wait_seconds" => 1}
  defp delete_input, do: %{"name" => "c1", "confirm" => "c1"}

  defp puts(fixture), do: Enum.count(HTTPFixture.requests(fixture), &(&1.method == "PUT"))

  defp respond_to(responses, request) do
    script = Agent.get(responses, & &1)

    case {request.method, request.target} do
      {"GET", "/1.0"} ->
        %{status: 200, body: sync(@server)}

      {"PUT", "/1.0/instances/c1/state"} ->
        if script[:lose_put] do
          %{raw: ""}
        else
          %{status: 202, body: async(operation("Running", 103))}
        end

      {"GET", "/1.0/operations/op-1/wait" <> _query} ->
        {status, code} = Map.get(script, :wait_status, {"Running", 103})
        %{status: 200, body: sync(operation(status, code))}

      _other ->
        %{status: 404, body: %{"type" => "error", "error" => "not found", "error_code" => 404}}
    end
  end

  defp operation(status, code) do
    %{
      "id" => "op-1",
      "class" => "task",
      "description" => "Starting instance",
      "created_at" => "2026-11-17T00:00:00Z",
      "updated_at" => "2026-11-17T00:00:00Z",
      "status" => status,
      "status_code" => code,
      "resources" => %{"instances" => ["/1.0/instances/c1"]},
      "metadata" => %{},
      "may_cancel" => false,
      "err" => "",
      "location" => "none"
    }
  end

  defp sync(metadata) do
    %{
      "type" => "sync",
      "status" => "Success",
      "status_code" => 200,
      "operation" => "",
      "error_code" => 0,
      "error" => "",
      "metadata" => metadata
    }
  end

  defp async(metadata) do
    %{
      "type" => "async",
      "status" => "Operation created",
      "status_code" => 100,
      "operation" => "/1.0/operations/op-1",
      "error_code" => 0,
      "error" => "",
      "metadata" => metadata
    }
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:macus, key, value)
  defp restore(key, :error), do: Application.delete_env(:macus, key)
end
