defmodule Macus.Incus.EvidenceTest do
  # Task 10.3: the linked shared-client coverage and library conformance,
  # validated independently from consumer and proxy reports, at the exact
  # locked library and reference revisions, with no evidence class
  # replacing another.
  use ExUnit.Case, async: true

  alias Macus.Incus.{Coverage, Evidence}
  alias Opsmaru.Incus.Operations.{Composite, Native}

  @path Path.expand("../../../../docs/incus-evidence.md", __DIR__)
  @dep_dir Path.expand("../../../deps/opsmaru_incus", __DIR__)
  @other_revision "0000000000000000000000000000000000000000"

  setup_all do
    records = Evidence.records()
    {:ok, reference} = Evidence.revisions(records)
    %{records: records, revision: reference["revision"]}
  end

  describe "the linked package" do
    test "every record is present and pins one reference revision", ctx do
      assert Enum.sort(Evidence.files()) == Enum.sort(Map.keys(ctx.records))

      for name <- Evidence.files(),
          do: assert(match?({:ok, _}, ctx.records[name]), name)

      {:ok, reference} = Evidence.revisions(ctx.records)
      assert reference["revision"] == ctx.revision
    end

    test "the locked, loaded and documented versions all agree", ctx do
      {:ok, summary} = Evidence.check()
      locked = Evidence.locked()
      loaded = Evidence.loaded()

      assert locked.version == loaded.version
      assert locked.checksum =~ ~r/\A[0-9a-f]{64}\z/
      assert Enum.uniq(Map.values(loaded.doc_versions)) == [locked.version]
      assert summary.reference["revision"] == ctx.revision
      assert summary.errors == []
      assert summary.records == length(Evidence.files())
      assert summary.integrity_files > 0
      assert summary.complete_port == Coverage.complete_port?()
      refute summary.complete_port
    end

    test "a record from another reference revision fails" do
      records =
        with_record(
          Evidence.records(),
          "coverage.json",
          Map.put(ctx_record("coverage.json"), "reference_revision", @other_revision)
        )

      assert {:error, errors} = Evidence.revisions(records)

      assert errors == [
               "evidence record coverage.json pins #{@other_revision}, not #{ctx_reference()["revision"]}"
             ]
    end

    test "a record with an unknown reference fails" do
      records = with_record(Evidence.records(), "methods.json", %{"reference_revision" => "nope"})

      assert {:error, errors} = Evidence.revisions(records)

      assert errors == [
               "evidence record methods.json pins an unknown reference revision \"nope\""
             ]
    end

    test "a missing record fails" do
      records = Map.put(Evidence.records(), "transfer.json", {:error, :enoent})

      assert {:error, errors} = Evidence.revisions(records)
      assert errors == [~s(evidence record transfer.json is missing or unreadable: :enoent)]
    end

    test "a reference record without a well-formed reference fails" do
      records = with_record(Evidence.records(), "reference.json", %{"tag" => "v7.0.1"})

      assert {:error, errors} = Evidence.revisions(records)
      assert Enum.any?(errors, &(&1 =~ "reference.json has no revision"))
    end

    test "a loaded package that is not the locked one fails" do
      library = %{locked: Evidence.locked(), loaded: Evidence.loaded()}
      assert Evidence.library_errors(library) == []

      other = %{library | locked: Map.put(library.locked, :version, "9.9.9")}

      assert Evidence.library_errors(other) == [
               "the composite operation document is version #{library.loaded.version}, not 9.9.9",
               "the loaded opsmaru_incus is #{library.loaded.version}, but mix.lock locks 9.9.9",
               "the native operation document is version #{library.loaded.version}, not 9.9.9"
             ]

      other = %{library | loaded: %{library.loaded | doc_versions: %{"composite" => "9.9.9"}}}

      assert Evidence.library_errors(other) == [
               "the composite operation document is version 9.9.9, not #{library.locked.version}"
             ]
    end
  end

  describe "library conformance linked, not rerun" do
    test "the shipped records hash to the package's own transfer.json", ctx do
      transfer = ctx_record("transfer.json")
      records = for %{"destination" => "priv/incus/" <> _} = file <- transfer["files"], do: file
      notices = for %{"destination" => "priv/notices/" <> _} = file <- transfer["files"], do: file

      n = length(records)
      assert {:ok, ^n} = Evidence.integrity(ctx.records)
      assert records != [] and notices != []
    end

    test "a record that no longer matches transfer.json fails" do
      transfer = ctx_record("transfer.json")

      tampered =
        Map.put(transfer, "files", [
          %{
            "source" => "priv/incus/reference.json",
            "destination" => "priv/incus/reference.json",
            "source_sha256" => "00",
            "transferred_sha256" => @other_revision <> "00"
          }
        ])

      assert {:error, errors} =
               Evidence.integrity(with_record(Evidence.records(), "transfer.json", tampered))

      assert errors == [
               "evidence record priv/incus/reference.json no longer hashes to " <>
                 "#{@other_revision}00 recorded in transfer.json"
             ]
    end

    test "a notice that no longer matches its amended digest fails" do
      transfer = ctx_record("transfer.json")

      notice =
        Enum.find(transfer["files"], &(&1["destination"] == "priv/notices/INCUS-NOTICE.md"))

      assert notice["amended_sha256"] && notice["amended_sha256"] != notice["transferred_sha256"]

      tampered =
        Map.put(transfer, "files", [Map.put(notice, "amended_sha256", @other_revision <> "00")])

      assert {:error, errors} =
               Evidence.integrity(with_record(Evidence.records(), "transfer.json", tampered))

      assert errors == [
               "notice priv/notices/INCUS-NOTICE.md no longer hashes to " <>
                 "#{@other_revision}00 recorded in transfer.json"
             ]

      # The transferred digest alone no longer describes the shipped, amended file.
      untracked = Map.put(transfer, "files", [Map.delete(notice, "amended_sha256")])

      assert {:error, [_]} =
               Evidence.integrity(with_record(Evidence.records(), "transfer.json", untracked))
    end

    test "a coverage entry outside the inventory fails the check" do
      records =
        with_record(Evidence.records(), "coverage.json", %{
          "entries" => [
            %{"id" => "client/method/ProtocolIncus.MadeUp", "status" => "complete"}
          ]
        })

      assert Evidence.well_formed_errors(records) == [
               "coverage entry client/method/ProtocolIncus.MadeUp names no declaration of the pinned inventory"
             ]
    end

    test "the records are self-consistent and complete claims ship implementations", ctx do
      assert Evidence.well_formed_errors(ctx.records) == []

      for entry <- ctx_record("coverage.json")["entries"],
          is_binary(entry["elixir"]) and entry["elixir"] != "" do
        assert File.exists?(Path.join(@dep_dir, entry["elixir"])), entry["id"]
      end
    end
  end

  describe "no evidence class replaces another" do
    test "relay fixtures are relay evidence, never library conformance" do
      relay = "test/gateway_upgrade_test.exs"
      assert Evidence.classify(relay) == :relay
      refute Evidence.countable_as?(:library, relay)
      assert Coverage.substitute?(relay)
    end

    test "a proxy/relay fixture result offered as a complete claim fails the check" do
      coverage = ctx_record("coverage.json")
      inventory = ctx_record("inventory.json")
      id = hd(coverage["entries"])["id"]

      entry = %{
        "id" => id,
        "status" => "complete",
        "elixir" => "lib/opsmaru/incus.ex",
        "evidence" => [
          "test/gateway_upgrade_test.exs",
          "server/test/macus/proxy/native_relay_test.exs"
        ]
      }

      records = with_record(Evidence.records(), "coverage.json", put_entry(coverage, entry))

      assert Evidence.well_formed_errors(records) ==
               [
                 "coverage entry #{id} claims complete but only relay or consumer evidence backs it"
               ]

      # And the reused gap rule still refuses the complete-port claim.
      refute Coverage.complete_port?(
               Map.put(coverage, "complete_port", true),
               inventory
             )
    end

    test "Macus consumer tests offered as library coverage fail the check" do
      coverage = ctx_record("coverage.json")
      id = hd(coverage["entries"])["id"]

      entry = %{
        "id" => id,
        "status" => "complete",
        "elixir" => "lib/opsmaru/incus.ex",
        "evidence" => ["server/test/macus/incus/shared_client_test.exs"]
      }

      records = with_record(Evidence.records(), "coverage.json", put_entry(coverage, entry))

      assert Evidence.well_formed_errors(records) ==
               [
                 "coverage entry #{id} claims complete but only relay or consumer evidence backs it"
               ]
    end

    test "consumer paths classify as consumer evidence, not library or relay" do
      assert Evidence.classify("server/test/macus/incus/shared_client_test.exs") == :consumer
      assert Evidence.classify("server/test/macus/mcp/execute_test.exs") == :consumer
      assert Evidence.classify("server/test/macus_web/mcp_test.exs") == :consumer

      refute Evidence.countable_as?(
               :library,
               "server/test/macus/incus/shared_client_test.exs"
             )
    end

    test "proxy paths classify as relay evidence" do
      assert Evidence.classify("server/test/macus/proxy/native_relay_test.exs") == :relay
      assert Evidence.classify("server/test/macus/incus/reference_wire_test.exs") == :relay
      refute Evidence.countable_as?(:consumer, "server/test/macus/proxy/native_relay_test.exs")
      refute Evidence.countable_as?(:library, "server/test/macus/proxy/native_relay_test.exs")
    end

    test "library evidence is never guest or hardware acceptance" do
      for path <- ~w(priv/incus/coverage.json priv/incus/inventory.json
                     test/discovery_helpers_test.exs) do
        assert Evidence.classify(path) == :library
        refute Evidence.countable_as?(:hardware, path), path
        refute Evidence.countable_as?(:consumer, path), path
      end

      assert Evidence.classify("docs/testing/alpine-hardware-acceptance.json") == :hardware

      assert Evidence.countable_as?(
               :hardware,
               "docs/testing/alpine-hardware-acceptance.json"
             )

      # And the check itself claims none.
      {:ok, summary} = Evidence.check()
      assert summary.hardware =~ "none claimed"
    end

    test "evidence from a different library version fails" do
      library = %{locked: Evidence.locked(), loaded: Evidence.loaded()}
      other = %{library | loaded: %{library.loaded | version: "9.9.9"}}

      assert Evidence.library_errors(other) == [
               "the loaded opsmaru_incus is 9.9.9, but mix.lock locks #{library.locked.version}"
             ]
    end
  end

  describe "shared-client coverage linked" do
    test "every Macus binding resolves to library evidence" do
      assert Evidence.binding_errors(Evidence.bindings()) == []
    end

    test "a binding with no library entry is reported, not counted" do
      bindings =
        Evidence.bindings() ++ [{"a binding to nothing", "GetMadeUpMethod", []}]

      assert Evidence.binding_errors(bindings) == [
               "no library evidence for the a binding to nothing binding: " <>
                 "GetMadeUpMethod (:no_method_evidence)"
             ]
    end

    test "every operation Macus exposes is a library operation, not an unavailable one" do
      assert Evidence.operations_errors() == []

      operations = Macus.MCP.Manifest.operations()
      assert Enum.any?(operations, &(&1.source == "opsmaru_incus"))
      assert Enum.any?(operations, &(&1.source == "opsmaru_incus_native"))
    end

    test "exposing an operation the library marks unavailable fails the check" do
      [unavailable | _] = Native.unavailable()

      assert Evidence.operations_errors([native_op(unavailable["name"])]) == [
               "#{unavailable["name"]} is exposed by Macus but the native library " <>
                 "marks it unavailable"
             ]

      [deferred | _] = Composite.unavailable()

      assert Evidence.operations_errors([composite_op(deferred["name"])]) == [
               "#{deferred["name"]} is exposed by Macus but the composite library " <>
                 "marks it unavailable"
             ]
    end

    test "exposing an operation the library does not have fails the check" do
      assert Evidence.operations_errors([composite_op("incus_made_up")]) == [
               "incus_made_up is exposed by Macus but no composite library operation has it"
             ]
    end

    test "the unavailable operations are reported and never exposed" do
      unavailable = Evidence.unavailable()
      assert length(unavailable) == length(Composite.unavailable()) + length(Native.unavailable())

      exposed =
        Macus.MCP.Manifest.operations()
        |> Enum.filter(&(&1.source in ["opsmaru_incus", "opsmaru_incus_native"]))
        |> Enum.map(& &1.operation_id)

      for %{"name" => name} <- unavailable, do: refute(name in exposed)
    end
  end

  describe "the compiled call cross-check" do
    test "every call Macus's compiled code makes is covered by a binding entry" do
      calls = Evidence.called_mfas()
      assert map_size(calls) > 0
      assert Evidence.call_errors() == []
    end

    test "every MFA a binding entry lists is one the compiled code actually calls" do
      calls = Evidence.called_mfas()

      for binding <- Evidence.bindings(), mfa <- elem(binding, 2) do
        assert mfa in Map.keys(calls),
               "#{elem(binding, 0)} lists #{inspect(mfa)}, which no Macus code calls"
      end
    end

    test "a call no entry covers fails, naming the caller and the MFA" do
      calls = Map.put(Evidence.called_mfas(), {Opsmaru.Incus, :raw_query, 9}, [Macus.Proxy.Host])

      assert Evidence.call_error_list(calls, Evidence.bindings()) == [
               "Macus.Proxy.Host calls Opsmaru.Incus.raw_query/9, which no " <>
                 "shared-client binding entry covers"
             ]
    end

    test "an entry listing an MFA no Macus code calls fails, naming the entry" do
      stale =
        Enum.map(Evidence.bindings(), fn binding ->
          if elem(binding, 0) =~ "client workers" do
            {elem(binding, 0), elem(binding, 1), elem(binding, 2) ++ [{Opsmaru.Incus, :nbd, 2}]}
          else
            binding
          end
        end)

      assert Evidence.call_error_list(Evidence.called_mfas(), stale) == [
               "binding \"client workers (Macus.Incus.run/3)\" lists " <>
                 "Opsmaru.Incus.nbd/2, which no Macus code calls"
             ]
    end

    test "the cross-check is part of the whole check" do
      assert {:ok, summary} = Evidence.check()
      assert summary.errors == []
      assert summary.covered_calls == map_size(Evidence.called_mfas())
    end
  end

  describe "the task and the page" do
    # Mix refuses to run the same task twice at once, so the check and the
    # page assertion share one test.
    test "mix macus.incus.evidence --check passes and the page is current" do
      assert :ok = Mix.Task.run("macus.incus.evidence", ["--check"])
      page = File.read!(@path)

      assert page =~ "| Complete port | no"
      assert page =~ "none claimed; a separate, opt-in class"
      assert page =~ "Hex outer checksum"
      assert page =~ Evidence.locked().checksum
      assert page =~ ctx_reference()["revision"]
      assert page =~ "## Linked bindings"
      assert page =~ "## Library operations Macus does not expose"
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp ctx_record(name), do: Evidence.records()[name] |> elem(1)

  defp ctx_reference, do: ctx_record("reference.json")

  # Replaces one record in the record set, keeping its `{:ok, _}` shape.
  defp with_record(records, name, record), do: Map.put(records, name, {:ok, record})

  defp put_entry(coverage, entry) do
    entries =
      coverage["entries"]
      |> Enum.map(fn current ->
        if current["id"] == entry["id"], do: entry, else: current
      end)

    Map.put(coverage, "entries", entries)
  end

  defp native_op(name) do
    %{
      cassette: "opsmaru_incus",
      source: "opsmaru_incus_native",
      operation_id: name,
      summary: "",
      scopes: [],
      destructive: false,
      confirmation: nil
    }
  end

  defp composite_op(name) do
    %{
      cassette: "opsmaru_incus",
      source: "opsmaru_incus",
      operation_id: name,
      summary: "",
      scopes: [],
      destructive: false,
      confirmation: nil
    }
  end
end
