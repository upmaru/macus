defmodule Macus.Incus.CoverageTest do
  # Tasks 2.3 and 2.4: fixture provenance and the shared client's coverage,
  # read from the locked :opsmaru_incus package.
  use ExUnit.Case, async: true

  alias Macus.Incus.Coverage

  @server Path.expand("../../..", __DIR__)
  @docs Path.expand("../docs", @server)

  # Fixtures Macus transferred and still keeps as its own relay and binding
  # evidence.
  @retained ~w(
    priv/notices/incus-APACHE-2.0.txt
    priv/notices/INCUS-NOTICE.md
    test/reference/main.go
    test/reference/go.mod
    test/reference/go.sum
    test/fixtures/incus/wire.json
    test/support/http_fixture.ex
    test/support/wire_comparison.ex
    test/support/tls_identity.ex
  )

  # Transferred files Macus no longer carries: it reads the dependency's.
  @referenced ~w(
    priv/incus/reference.json
    priv/incus/inventory.json
    scripts/incus-inventory.go
    scripts/incus-inventory_test.go
    lib/macus/incus/inventory.ex
    lib/mix/tasks/macus.incus.inventory.ex
    test/macus/incus/inventory_test.exs
  )

  setup_all do
    %{coverage: Coverage.coverage(), inventory: Coverage.inventory()}
  end

  describe "transferred fixtures" do
    test "every transferred file is either kept as Macus evidence or read from the dependency" do
      transfer = Coverage.transfer()
      assert transfer["source_repository"] == "https://github.com/upmaru/macus"
      assert transfer["source_revision"] =~ ~r/\A[0-9a-f]{40}\z/
      sources = Enum.map(transfer["files"], & &1["source"])

      assert Enum.sort(sources) == Enum.sort(@retained ++ @referenced)

      for path <- @retained, do: assert(File.exists?(Path.join(@server, path)), path)
      for path <- @referenced, do: refute(File.exists?(Path.join(@server, path)), path)
    end

    test "the dependency ships the referenced records unchanged since the transfer" do
      for %{"source" => source, "destination" => "priv/" <> _ = destination} = file <-
            Coverage.transfer()["files"],
          source in @referenced or source == "priv/notices/incus-APACHE-2.0.txt" do
        path = Path.join(Application.app_dir(:opsmaru_incus), destination)
        digest = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
        assert digest == file["transferred_sha256"], destination
      end

      # The dependency carries its own Incus notice (it has edited it since).
      assert File.exists?(
               Path.join(Application.app_dir(:opsmaru_incus), "priv/notices/INCUS-NOTICE.md")
             )

      # The inventory diff is the library's.
      assert Code.ensure_loaded?(Opsmaru.Incus.Inventory)
      refute Code.ensure_loaded?(Macus.Incus.Inventory)
      assert Code.ensure_loaded?(Mix.Tasks.Opsmaru.Incus.Inventory)
    end
  end

  describe "the dependency's coverage" do
    test "covers exactly the pinned inventory and exposes every gap", ctx do
      ids = Enum.map(ctx.inventory["entries"], & &1["id"])
      assert length(ids) == length(Enum.uniq(ids))
      assert Enum.sort(ids) == Enum.sort(Enum.map(ctx.coverage["entries"], & &1["id"]))

      gaps = Coverage.gaps(ctx.coverage, ctx.inventory)
      by_status = Enum.frequencies_by(ctx.coverage["entries"], & &1["status"])
      not_complete = length(ids) - Map.get(by_status, "complete", 0)
      assert length(gaps) == not_complete

      missing = for %{"status" => "missing", "id" => id} <- ctx.coverage["entries"], do: id
      assert missing != []
      for id <- missing, do: assert({id, {:status, "missing"}} in gaps)
    end

    test "a declaration absent from the coverage record, or an unknown entry, is a gap", ctx do
      [dropped | rest] = ctx.coverage["entries"]
      extra = %{dropped | "id" => "client/function/NotInTheReference"}
      coverage = %{ctx.coverage | "entries" => [extra | rest]}

      gaps = Coverage.gaps(coverage, ctx.inventory)
      assert {dropped["id"], :not_in_coverage} in gaps
      assert {"client/function/NotInTheReference", :not_in_inventory} in gaps
    end

    test "a complete-port claim fails without full evidence", ctx do
      refute ctx.coverage["complete_port"]
      refute Coverage.complete_port?()

      # A claim alone is not enough.
      refute Coverage.complete_port?(%{ctx.coverage | "complete_port" => true}, ctx.inventory)

      complete = complete(ctx.coverage)
      assert Coverage.gaps(complete, ctx.inventory) == []
      assert Coverage.complete_port?(complete, ctx.inventory)
      refute Coverage.complete_port?(%{complete | "complete_port" => false}, ctx.inventory)

      for {change, reason} <- [
            {%{"status" => "partial"}, {:status, "partial"}},
            {%{"elixir" => nil}, :no_implementation},
            {%{"evidence" => []}, :no_evidence}
          ] do
        coverage = update_first(complete, change)
        id = hd(coverage["entries"])["id"]
        assert Coverage.gaps(coverage, ctx.inventory) == [{id, reason}]
        refute Coverage.complete_port?(coverage, ctx.inventory)
      end
    end

    test "relay and Macus fixtures never stand in for typed-client evidence", ctx do
      complete = complete(ctx.coverage)

      for evidence <- [
            ["test/gateway_http_relay_test.exs"],
            ["test/gateway_reference_wire_test.exs", "test/gateway_raw_upgrade_test.exs"],
            ["server/test/macus/proxy/native_relay_test.exs"],
            ["test/macus/incus/shared_client_test.exs"]
          ] do
        coverage = update_first(complete, %{"evidence" => evidence})
        id = hd(coverage["entries"])["id"]
        assert Coverage.gaps(coverage, ctx.inventory) == [{id, :relay_or_consumer_evidence_only}]
        refute Coverage.complete_port?(coverage, ctx.inventory)
      end

      # Library client evidence alongside relay evidence still counts.
      coverage =
        update_first(complete, %{
          "evidence" => ["test/gateway_http_relay_test.exs", "test/client_test.exs"]
        })

      assert Coverage.complete_port?(coverage, ctx.inventory)
    end
  end

  describe "dependency updates" do
    test "the diff names added, removed and changed declarations", ctx do
      [removed, changed | rest] = ctx.inventory["entries"]
      added = %{changed | "id" => "client/method/ProtocolIncus.NewOperation"}
      altered = %{changed | "signature" => changed["signature"] <> " // changed"}
      previous = %{ctx.inventory | "entries" => [removed, changed | rest]}
      current = %{ctx.inventory | "entries" => [added, altered | rest]}

      assert Opsmaru.Incus.Inventory.diff(previous, current) == %{
               added: [added["id"]],
               removed: [removed["id"]],
               changed: [changed["id"]]
             }

      # A changed source file changes its declarations even when their
      # signatures do not.
      [source | others] = ctx.inventory["sources"]

      moved = %{
        ctx.inventory
        | "sources" => [%{source | "sha256" => String.duplicate("0", 64)} | others]
      }

      assert Opsmaru.Incus.Inventory.diff(ctx.inventory, moved).changed != []
    end

    test "mix macus.incus.coverage --diff reports them", ctx do
      dir = Path.join(System.tmp_dir!(), "mc-cov-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      [removed | rest] = ctx.inventory["entries"]
      previous = %{ctx.inventory | "entries" => rest ++ [%{removed | "id" => "client/type/Gone"}]}
      path = Path.join(dir, "previous.json")
      File.write!(path, Jason.encode!(previous))

      Mix.shell(Mix.Shell.Process)

      try do
        Mix.Task.rerun("macus.incus.coverage", ["--diff", path])
      after
        Mix.shell(Mix.Shell.IO)
      end

      assert_received {:mix_shell, :info, ["added: 1"]}
      added = "  " <> removed["id"]
      assert_received {:mix_shell, :info, [^added]}
      assert_received {:mix_shell, :info, ["removed: 1"]}
      assert_received {:mix_shell, :info, ["  client/type/Gone"]}
      assert_received {:mix_shell, :info, ["changed: 0"]}
    end
  end

  describe "documentation" do
    test "docs/incus-coverage.md is current" do
      assert File.read!(Path.join(@docs, "incus-coverage.md")) == Coverage.markdown(),
             "run `mix macus.incus.coverage` to regenerate docs/incus-coverage.md"
    end

    test "the coverage page reports the locked version and makes no complete-port claim" do
      page = Coverage.markdown()

      assert page =~
               "| Dependency | `opsmaru_incus` #{Macus.Build.identity().opsmaru_incus.version} |"

      assert page =~ "| Complete port | no |"
    end

    test "the guide names the evidence owners, the kept fixtures and the update steps" do
      guide = File.read!(Path.join(@docs, "incus-client.md"))

      for path <- [
            "server/test/fixtures/incus/wire.json",
            "server/test/reference",
            "server/priv/notices"
          ],
          do: assert(guide =~ "`#{path}`")

      assert guide =~ "mix macus.incus.coverage --diff"
      assert guide =~ "Library fixture success never completes Macus hardware acceptance."
      assert guide =~ "`test/gateway_*`"
      assert guide =~ "client_workers: n"
    end
  end

  # Every inventory declaration complete with an implementation and library
  # evidence, and a complete-port claim.
  defp complete(coverage) do
    entries =
      Enum.map(coverage["entries"], fn entry ->
        %{
          entry
          | "status" => "complete",
            "elixir" => entry["elixir"] || "lib/opsmaru/incus.ex",
            "evidence" => ["test/client_test.exs"]
        }
      end)

    %{coverage | "entries" => entries, "complete_port" => true}
  end

  defp update_first(%{"entries" => [first | rest]} = coverage, change),
    do: %{coverage | "entries" => [Map.merge(first, change) | rest]}
end
