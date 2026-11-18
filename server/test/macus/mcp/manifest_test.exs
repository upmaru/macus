defmodule Macus.MCP.ManifestTest do
  # A private index under its own name; no application environment.
  use ExUnit.Case, async: true

  alias Macus.MCP.Manifest
  alias Macus.TestSupport.DexFixtures
  alias Opsmaru.Incus.Operations.{Composite, Native}

  @docs Path.expand("../../../../docs", __DIR__)

  setup_all do
    dir = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(dir) end)

    version = Macus.Build.identity().opsmaru_incus.version

    # The same documents the opsmaru_incus release cassette carries, plus the
    # local macus document, exactly as the server installs them.
    cassette =
      DexFixtures.cassette!(dir, "opsmaru_incus", version, [Composite.openapi(), Native.openapi()])

    index = :"manifest_index_#{System.unique_integer([:positive])}"
    start_supervised!({Tama.Dex.Index, path: :memory, name: index})
    {:ok, _} = Tama.Dex.import(index, cassette.path, sha256: cassette.sha256)
    {:ok, _} = Tama.Dex.load(index, Macus.Dex.RuntimeDocument.document(), cassette: "macus")

    %{index: index, version: version}
  end

  describe "the operation manifest" do
    test "docs/mcp-operations.md is current" do
      assert File.read!(Path.join(@docs, "mcp-operations.md")) == Manifest.markdown(),
             "run `mix macus.mcp.manifest` to regenerate docs/mcp-operations.md"
    end

    test "documents every loaded operation and nothing else", ctx do
      operations = Manifest.operations()

      loaded =
        for %{cassette: cassette, sources: sources} <- Tama.Dex.cassettes(ctx.index),
            %{source: source, operations: count} <- sources,
            into: %{},
            do: {{cassette, source}, count}

      documented = Enum.frequencies_by(operations, &{&1.cassette, &1.source})
      assert documented == loaded

      assert Map.keys(loaded) |> Enum.sort() == [
               {"macus", "macus"},
               {"opsmaru_incus", "opsmaru_incus"},
               {"opsmaru_incus", "opsmaru_incus_native"}
             ]

      for op <- operations do
        assert {:ok, loaded} =
                 Tama.Dex.describe(ctx.index, op.cassette, op.operation_id, scopes: op.scopes),
               "#{op.cassette}/#{op.operation_id} is documented but not loaded"

        assert loaded.source == op.source
        assert loaded.scopes == op.scopes
        assert loaded.destructive == op.destructive
        assert (loaded.confirmation && loaded.confirmation.field) == op.confirmation
      end
    end

    test "names the locked opsmaru_incus version", ctx do
      markdown = Manifest.markdown()
      assert markdown =~ "| `opsmaru_incus` | `opsmaru_incus` | #{ctx.version} |"
      assert markdown =~ "| `opsmaru_incus` | `opsmaru_incus_native` | #{ctx.version} |"
    end

    test "every operation needs exactly one documented scope and every confirmation is destructive" do
      scopes = MapSet.new(Macus.Auth.Token.scopes())

      for op <- Manifest.operations() do
        assert [scope] = op.scopes
        assert scope in scopes, "#{op.operation_id} needs #{scope}, which Macus does not issue"
        if op.confirmation, do: assert(op.destructive, op.operation_id)
      end
    end
  end

  describe "the MCP guide" do
    setup do
      %{guide: File.read!(Path.join(@docs, "mcp.md"))}
    end

    test "documents the scopes Macus issues", ctx do
      [_, section] = String.split(ctx.guide, "## Scopes decide what an agent sees", parts: 2)
      [table | _] = String.split(section, "\n## ", parts: 2)

      documented =
        Regex.scan(~r/`((?:incus|runtime)\.[a-z.]+)`/, table, capture: :all_but_first)
        |> List.flatten()
        |> MapSet.new()

      assert documented == MapSet.new(Macus.Auth.Token.scopes())
    end

    test "states the search bounds the tool enforces", ctx do
      schema = Tama.Dex.MCP.search_tool().input_schema["properties"]
      limit = schema["limit"]

      assert ctx.guide =~
               "| 1 to #{limit["maximum"]}, default #{limit["default"]} |"

      assert limit["minimum"] == 1
      assert ctx.guide =~ "At most #{schema["query"]["maxLength"]} characters"
      assert ctx.guide =~ "At most #{schema["tags"]["maxItems"]} |"

      assert Map.keys(schema) |> Enum.sort() ==
               ~w(cassette include_schemas limit query source tags)

      for argument <- Map.keys(schema), do: assert(ctx.guide =~ "| `#{argument}` |")
    end

    test "lists every execute error kind with whether it dispatched", ctx do
      execute = Tama.Dex.MCP.execute_tool()
      assert Enum.sort(execute.input_schema["required"]) == ~w(cassette input operation_id)

      for kind <- ~w(not_found not_ready no_executor invalid_input confirmation_required) do
        assert ctx.guide =~ "| `#{kind}` | false |"
      end

      for kind <- ~w(dispatch_failed invalid_output) do
        assert ctx.guide =~ "| `#{kind}` | true |"
      end

      assert ctx.guide =~ "| `operation_error` (in place of `error`) | true |"
    end

    test "names the two tools and only operations that exist", ctx do
      ids = MapSet.new(Manifest.operations(), & &1.operation_id)

      for id <- Regex.scan(~r/`((?:incus|macus)_[a-z_]+)`/, ctx.guide, capture: :all_but_first) do
        assert hd(id) in ids, "the guide names #{hd(id)}, which is not an operation"
      end

      # MacusWeb.MCPTest checks that tools/list returns exactly these two.
      assert ctx.guide =~ "exactly two tools: `search`, to find an operation, and `execute`"
    end
  end
end
