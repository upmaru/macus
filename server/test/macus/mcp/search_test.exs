defmodule Macus.MCP.SearchTest do
  # The index is registered under Macus.Dex.Index, so run serially.
  use ExUnit.Case, async: false

  alias Macus.MCP
  alias Macus.MCP.Tools.{Execute, Search}
  alias Macus.TestSupport.DexFixtures
  alias Opsmaru.Incus.Operations.{Composite, Native}

  @all_incus ["incus.read", "incus.write", "incus.exec", "incus.delete"]

  setup_all do
    dir = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(dir) end)

    cassette =
      DexFixtures.cassette!(dir, "opsmaru_incus", "0.2.0", [Composite.openapi(), Native.openapi()])

    ports_before = network_ports()
    start_supervised!({Tama.Dex.Index, path: :memory, name: Macus.Dex.Index})

    {:ok, _} = Tama.Dex.import(Macus.Dex.Index, cassette.path, sha256: cassette.sha256)

    macus = DexFixtures.document("macus", ["macus_instance_state", "macus_runtime_status"])
    {:ok, _} = Tama.Dex.load(Macus.Dex.Index, macus, cassette: "macus")

    %{ports_before: ports_before}
  end

  describe "the tool module" do
    test "advertises the tama-dex search definition with no tool-level scope" do
      definition = Search.definition()
      tool = Tama.Dex.MCP.search_tool()

      assert definition["title"] == tool.title
      assert definition["inputSchema"] == tool.input_schema
      assert definition["outputSchema"] == tool.output_schema
      assert definition["annotations"].readOnlyHint == true
      assert Search.scopes() == []
      assert Search.task_policy() == :disabled
    end

    test "searching opens no endpoint or listener", ctx do
      search!(%{"query" => "instance"}, @all_incus)
      # No port opened since before the index started. An earlier module's
      # socket may still be closing, so a port that went away is not a
      # failure.
      assert network_ports() -- ctx.ports_before == []
    end
  end

  describe "results" do
    test "both cassettes are ranked together, each result naming its cassette and version" do
      %{"results" => results} =
        search!(%{"query" => "instance state", "limit" => 20}, ["fixture.read" | @all_incus])

      by_cassette = Enum.group_by(results, & &1["cassette"])
      assert Map.keys(by_cassette) |> Enum.sort() == ["macus", "opsmaru_incus"]

      assert Enum.all?(by_cassette["opsmaru_incus"], &(&1["cassette_version"] == "0.2.0"))
      assert Enum.all?(results, &Map.has_key?(&1, "cassette_version"))

      ids = Enum.map(results, & &1["operation_id"])
      assert "macus_instance_state" in ids
      assert "incus_instance_state_get" in ids
    end

    test "the cassette filter limits results to one cassette" do
      %{"results" => results} =
        search!(%{"cassette" => "macus", "limit" => 20}, ["fixture.read" | @all_incus])

      assert results != []
      assert Enum.all?(results, &(&1["cassette"] == "macus"))
    end

    test "returned schemas match the loaded documents" do
      %{"results" => [result]} =
        search!(%{"query" => "incus_server_get", "limit" => 1}, ["incus.read"])

      assert result["operation_id"] == "incus_server_get"
      assert result["input_schema"] == request_schema(Composite.openapi(), "incus_server_get")
      assert result["scopes"] == ["incus.read"]
      assert result["destructive"] == false

      %{"results" => [omitted]} =
        search!(
          %{"query" => "incus_server_get", "limit" => 1, "include_schemas" => false},
          ["incus.read"]
        )

      refute Map.has_key?(omitted, "input_schema")
    end

    test "destructive operations carry their confirmation field" do
      %{"results" => results} = search!(%{"query" => "delete", "limit" => 20}, ["incus.delete"])
      delete = Enum.find(results, &(&1["operation_id"] == "incus_instance_delete"))

      assert delete["destructive"] == true
      assert %{"field" => "confirm"} = delete["confirmation"]
    end
  end

  describe "scope filtering" do
    test "results are limited to the caller's scopes" do
      %{"results" => results} = search!(%{"limit" => 20}, ["incus.read"])

      assert results != []
      assert Enum.all?(results, &("incus.read" in &1["scopes"]))
      refute Enum.any?(results, &(&1["cassette"] == "macus"))

      assert %{"results" => [], "truncated" => false} = search!(%{"query" => "instance"}, [])
    end

    test "native operations appear only to a caller holding native scopes" do
      for arguments <- [
            %{"limit" => 20},
            %{"query" => "instance", "limit" => 20},
            %{"source" => "opsmaru_incus_native", "limit" => 20}
          ] do
        %{"results" => results} = search!(arguments, @all_incus)
        refute Enum.any?(results, &(&1["source"] == "opsmaru_incus_native")), inspect(arguments)
      end

      %{"results" => results} =
        search!(%{"source" => "opsmaru_incus_native", "limit" => 20}, ["incus.native.read"])

      assert results != []
      assert Enum.all?(results, &(&1["source"] == "opsmaru_incus_native"))
      assert Enum.all?(results, &(&1["scopes"] == ["incus.native.read"]))
    end

    test "a search result does not bypass execute authorization" do
      %{"results" => results} = search!(%{"query" => "delete", "limit" => 20}, ["incus.delete"])
      assert Enum.any?(results, &(&1["operation_id"] == "incus_instance_delete"))

      arguments = %{
        "cassette" => "opsmaru_incus",
        "operation_id" => "incus_instance_delete",
        "input" => %{"name" => "c1", "confirm" => "c1"}
      }

      {:ok, response} = Execute.call(arguments, context(["incus.read"]))
      assert response.is_error

      assert %{"error" => %{"kind" => "not_found", "dispatched" => false}} =
               response.structured_content
    end
  end

  describe "bounds" do
    test "result counts and response size are bounded" do
      structured = search!(%{"limit" => 20}, @all_incus)

      # 32 shared operations are visible; the limit caps the page, and the
      # encoded response stays within the 64 KiB tama-dex budget.
      assert length(structured["results"]) == 20
      assert byte_size(Jason.encode!(structured)) <= 65_536

      %{"results" => default} = search!(%{}, @all_incus)
      assert length(default) == 5

      for arguments <- [
            %{"limit" => 21},
            %{"limit" => 0},
            %{"query" => String.duplicate("é", 300)},
            %{"tags" => Enum.map(1..17, &"t#{&1}")},
            %{"unknown" => true}
          ] do
        assert %{"error" => %{"kind" => "invalid_arguments", "dispatched" => false}} =
                 search!(arguments, @all_incus, :tool_error)
      end
    end

    test "an absent index is not ready" do
      assert %{"error" => %{"kind" => "not_ready", "dispatched" => false}} =
               MCP.search(%{}, context(@all_incus), :macus_absent_index)
    end
  end

  # Calls the tool module and checks the response kind and output schema.
  defp search!(arguments, scopes, expected \\ :success) do
    {:ok, response} = Search.call(arguments, context(scopes))

    assert response.is_error == (expected == :tool_error)
    [%{"text" => text}] = response.content
    assert Jason.decode!(text) == response.structured_content

    {:ok, schema} = JSONSchex.compile(Search.definition()["outputSchema"], draft: "draft2020_12")
    assert :ok = JSONSchex.validate(schema, response.structured_content)
    response.structured_content
  end

  defp context(scopes) do
    %TamaMCP.Context{
      request_id: 1,
      principal: "owner",
      owner_key: "owner-key-1",
      claims: %{},
      scopes: scopes
    }
  end

  defp request_schema(document, operation_id) do
    Enum.find_value(document["paths"], fn {_path, item} ->
      Enum.find_value(item, fn {_method, op} ->
        if op["operationId"] == operation_id,
          do: op["requestBody"]["content"]["application/json"]["schema"]
      end)
    end)
  end

  defp network_ports do
    for port <- Port.list(),
        Port.info(port, :name) in [{:name, ~c"tcp_inet"}, {:name, ~c"udp_inet"}],
        do: port
  end
end
