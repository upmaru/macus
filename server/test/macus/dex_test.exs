defmodule Macus.DexTest do
  # Telemetry handlers and cassette names are global, so run serially.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Bitwise

  alias Macus.{Configuration, Dex}
  alias Macus.Dex.Config
  alias Macus.TestSupport.DexFixtures

  @event [:macus, :dex, :cassette]
  @scopes ["fixture.read"]

  setup do
    root = DexFixtures.private_root!()
    server = Path.join(root, "server")
    File.mkdir!(server)
    File.chmod!(server, 0o700)
    bundle = Path.join(root, "bundle")
    File.mkdir!(bundle)
    on_exit(fn -> File.rm_rf!(root) end)

    handler = "macus-dex-test-#{System.unique_integer([:positive])}"
    :ok = :telemetry.attach(handler, @event, &DexFixtures.handle_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, state} = Configuration.new(root)

    %{
      root: root,
      server: server,
      bundle: bundle,
      uid: File.stat!(root).uid,
      index_path: Config.index_path(state)
    }
  end

  describe "installing cassettes at start" do
    test "imports the pinned cassette asynchronously and loads the local document", ctx do
      cassette = incus_cassette!(ctx, "1", ["incus_fixture_get", "incus_fixture_list"])
      dex = start_dex!(config!(ctx, imports: [pinned(cassette)], documents: [macus_document()]))

      assert_receive {:dex_event, "opsmaru_incus", :ready}, 5_000
      assert_receive {:dex_event, "macus", :ready}, 5_000

      readiness = Dex.readiness(dex.bootstrap)
      assert readiness.status == :ready

      assert %{kind: :imported, status: :ready, version: "1"} =
               readiness.cassettes["opsmaru_incus"]

      assert readiness.cassettes["opsmaru_incus"].serving_version == "1"
      assert %{kind: :local, status: :ready} = readiness.cassettes["macus"]

      assert {:ok, _} =
               Tama.Dex.describe(dex.index, "opsmaru_incus", "incus_fixture_get", scopes: @scopes)

      assert {:ok, _} =
               Tama.Dex.describe(dex.index, "macus", "macus_fixture_status", scopes: @scopes)

      stat = File.lstat!(ctx.index_path)
      assert stat.type == :regular
      assert band(stat.mode, 0o777) == 0o600
    end

    test "the real opsmaru_incus composite document builds and imports", ctx do
      document = Opsmaru.Incus.Operations.Composite.openapi()
      cassette = DexFixtures.cassette!(ctx.bundle, "opsmaru_incus", "0.2.0", [document])
      dex = start_dex!(config!(ctx, imports: [pinned(cassette)]))

      assert_receive {:dex_event, "opsmaru_incus", :ready}, 10_000

      assert [%{cassette: "opsmaru_incus", sources: [%{source: "opsmaru_incus", operations: 32}]}] =
               Tama.Dex.cassettes(dex.index)
    end

    test "the same operation ID may exist in both cassettes", ctx do
      cassette = incus_cassette!(ctx, "1", ["shared_status"])
      local = %{cassette: "macus", document: DexFixtures.document("macus", ["shared_status"])}
      dex = start_dex!(config!(ctx, imports: [pinned(cassette)], documents: [local]))

      assert_receive {:dex_event, "opsmaru_incus", :ready}, 5_000
      assert_receive {:dex_event, "macus", :ready}, 5_000

      assert {:ok, _} =
               Tama.Dex.describe(dex.index, "opsmaru_incus", "shared_status", scopes: @scopes)

      assert {:ok, _} = Tama.Dex.describe(dex.index, "macus", "shared_status", scopes: @scopes)
    end

    test "a document supplied as {module, function, args} is loaded", ctx do
      source = {DexFixtures, :document, ["macus", ["macus_fixture_mfa"]]}
      dex = start_dex!(config!(ctx, documents: [%{cassette: "macus", document: source}]))

      assert_receive {:dex_event, "macus", :ready}, 5_000

      assert {:ok, _} =
               Tama.Dex.describe(dex.index, "macus", "macus_fixture_mfa", scopes: @scopes)
    end
  end

  describe "rejected and replaced cassettes" do
    test "a pin mismatch is rejected with guidance while the previous version keeps serving",
         ctx do
      v1 = incus_cassette!(ctx, "1", ["incus_fixture_get"])
      dex = start_dex!(config!(ctx, imports: [pinned(v1)]))
      assert_receive {:dex_event, "opsmaru_incus", :ready}, 5_000
      stop_supervised!(dex.name)

      v2 = incus_cassette!(ctx, "2", ["incus_fixture_get", "incus_fixture_new"])
      dex = start_dex!(config!(ctx, imports: [%{pinned(v2) | sha256: v1.sha256}]))
      assert_receive {:dex_event, "opsmaru_incus", :failed}, 5_000

      readiness = Dex.readiness(dex.bootstrap)
      assert readiness.status == :failed
      entry = readiness.cassettes["opsmaru_incus"]
      assert entry.status == {:failed, :sha256_mismatch}
      assert entry.guidance =~ "Reinstall the matching Macus package"
      assert entry.serving_version == "1"

      assert {:error, :not_found} =
               Tama.Dex.describe(dex.index, "opsmaru_incus", "incus_fixture_new", scopes: @scopes)
    end

    test "an upgrade replaces the whole imported cassette and leaves macus untouched", ctx do
      v1 = incus_cassette!(ctx, "1", ["incus_fixture_get", "incus_fixture_old"])
      dex = start_dex!(config!(ctx, imports: [pinned(v1)], documents: [macus_document()]))
      assert_receive {:dex_event, "opsmaru_incus", :ready}, 5_000
      assert_receive {:dex_event, "macus", :ready}, 5_000
      stop_supervised!(dex.name)

      v2 = incus_cassette!(ctx, "2", ["incus_fixture_get"])
      dex = start_dex!(config!(ctx, imports: [pinned(v2)]))
      assert_receive {:dex_event, "opsmaru_incus", :ready}, 5_000

      assert Dex.readiness(dex.bootstrap).cassettes["opsmaru_incus"].version == "2"

      assert {:error, :not_found} =
               Tama.Dex.describe(dex.index, "opsmaru_incus", "incus_fixture_old", scopes: @scopes)

      assert {:ok, _} =
               Tama.Dex.describe(dex.index, "macus", "macus_fixture_status", scopes: @scopes)
    end

    test "loading the local document into an imported cassette name fails", ctx do
      cassette = incus_cassette!(ctx, "1", ["incus_fixture_get"])
      dex = start_dex!(config!(ctx, imports: [pinned(cassette)]))
      assert_receive {:dex_event, "opsmaru_incus", :ready}, 5_000
      stop_supervised!(dex.name)

      intruder = %{cassette: "opsmaru_incus", document: DexFixtures.document("macus", ["x_op"])}
      dex = start_dex!(config!(ctx, documents: [intruder]))
      assert_receive {:dex_event, "opsmaru_incus", :failed}, 5_000

      entry = Dex.readiness(dex.bootstrap).cassettes["opsmaru_incus"]
      assert entry.status == {:failed, :cassette_conflict}
      assert entry.guidance =~ "already uses this name"

      assert {:ok, _} =
               Tama.Dex.describe(dex.index, "opsmaru_incus", "incus_fixture_get", scopes: @scopes)
    end

    test "a missing bundled cassette is reported, not fetched", ctx do
      missing = %{cassette: "opsmaru_incus", path: Path.join(ctx.bundle, "absent.tama-cassette")}

      dex =
        start_dex!(config!(ctx, imports: [Map.put(missing, :sha256, String.duplicate("a", 64))]))

      assert_receive {:dex_event, "opsmaru_incus", :failed}, 5_000
      entry = Dex.readiness(dex.bootstrap).cassettes["opsmaru_incus"]
      assert entry.status == {:failed, {:file, :enoent}}
      assert entry.guidance =~ "missing"
    end
  end

  describe "index recovery" do
    test "a deleted index is recreated from the bundle", ctx do
      cassette = incus_cassette!(ctx, "1", ["incus_fixture_get"])
      config = config!(ctx, imports: [pinned(cassette)])

      dex = start_dex!(config)
      assert_receive {:dex_event, "opsmaru_incus", :ready}, 5_000
      stop_supervised!(dex.name)

      for suffix <- ["", "-wal", "-shm"], do: File.rm(ctx.index_path <> suffix)
      refute File.exists?(ctx.index_path)

      dex = start_dex!(config)
      assert_receive {:dex_event, "opsmaru_incus", :ready}, 5_000
      assert File.exists?(ctx.index_path)

      assert {:ok, _} =
               Tama.Dex.describe(dex.index, "opsmaru_incus", "incus_fixture_get", scopes: @scopes)
    end

    test "an index with an unknown schema version is recreated", ctx do
      cassette = incus_cassette!(ctx, "1", ["incus_fixture_get"])
      config = config!(ctx, imports: [pinned(cassette)])

      dex = start_dex!(config)
      assert_receive {:dex_event, "opsmaru_incus", :ready}, 5_000
      stop_supervised!(dex.name)

      {:ok, conn} = Exqlite.Sqlite3.open(ctx.index_path)

      :ok =
        Exqlite.Sqlite3.execute(
          conn,
          "UPDATE meta SET value = '999' WHERE key = 'schema_version'"
        )

      :ok = Exqlite.Sqlite3.close(conn)

      dex = start_dex!(config)
      assert_receive {:dex_event, "opsmaru_incus", :ready}, 5_000

      assert {:ok, _} =
               Tama.Dex.describe(dex.index, "opsmaru_incus", "incus_fixture_get", scopes: @scopes)
    end
  end

  describe "owner-private state and configuration" do
    test "an unsafe gateway directory opens nothing", ctx do
      File.chmod!(ctx.server, 0o755)
      dex = start_dex!(config!(ctx, documents: [macus_document()]))

      readiness = Dex.readiness(dex.bootstrap)
      assert readiness.status == :failed
      assert readiness.failure == {:index_path, :unsafe}
      assert readiness.guidance =~ "owner-private"
      refute File.exists?(ctx.index_path)
      refute Process.whereis(dex.index)
    end

    test "a missing gateway directory is not created", ctx do
      File.rmdir!(ctx.server)
      dex = start_dex!(config!(ctx, documents: [macus_document()]))

      readiness = Dex.readiness(dex.bootstrap)
      assert readiness.failure == {:index_path, :enoent}
      assert readiness.guidance =~ "macus start"
      refute File.exists?(ctx.server)
    end

    test "an index file that is not owner-private is refused", ctx do
      File.write!(ctx.index_path, "")
      File.chmod!(ctx.index_path, 0o644)
      dex = start_dex!(config!(ctx, documents: [macus_document()]))

      assert Dex.readiness(dex.bootstrap).failure == {:index_path, :unsafe}
    end

    test "every bundled cassette needs a local path and a pin", ctx do
      base = %{cassette: "opsmaru_incus", path: Path.join(ctx.bundle, "c.tama-cassette")}

      assert {:error, {:unpinned_cassette, "opsmaru_incus"}} =
               Config.new(index_path: :memory, owner_uid: ctx.uid, imports: [base])

      remote = %{base | path: "https://example.invalid/c.tama-cassette"}

      assert {:error, {:invalid_bundle_path, "opsmaru_incus"}} =
               Config.new(
                 index_path: :memory,
                 owner_uid: ctx.uid,
                 imports: [Map.put(remote, :sha256, String.duplicate("a", 64))]
               )

      dex = start_dex!(Config.new(index_path: :memory, owner_uid: ctx.uid, imports: [base]))
      readiness = Dex.readiness(dex.bootstrap)
      assert readiness.status == :failed
      assert readiness.failure == :unpinned_cassette
      assert readiness.guidance =~ "SHA-256 pin"
    end

    test "the subtree is disabled by default and unavailable when absent", ctx do
      {:ok, state} = Configuration.new(ctx.root)
      assert Dex.children([], state) == []
      assert [%{restart: :temporary}] = Dex.children([enabled: true, owner_uid: ctx.uid], state)

      assert Dex.readiness(:"macus_dex_absent_#{System.unique_integer([:positive])}").status ==
               :unavailable
    end
  end

  describe "isolation from the rest of Macus" do
    test "a missed deadline fails only that cassette", ctx do
      cassette = incus_cassette!(ctx, "1", ["incus_fixture_get"])
      ids = for n <- 1..400, do: "macus_fixture_#{n}"
      slow = %{cassette: "macus", document: DexFixtures.document("macus", ids)}

      dex =
        start_dex!(config!(ctx, imports: [pinned(cassette)], documents: [slow], load_timeout: 1))

      assert_receive {:dex_event, "opsmaru_incus", :ready}, 5_000
      assert_receive {:dex_event, "macus", :failed}, 5_000

      readiness = Dex.readiness(dex.bootstrap)
      assert readiness.status == :degraded
      assert readiness.cassettes["macus"].status == {:failed, :deadline}
      assert readiness.cassettes["macus"].guidance =~ "deadline"

      assert {:error, :not_found} =
               Tama.Dex.describe(dex.index, "macus", "macus_fixture_1", scopes: @scopes)
    end

    test "a crashing index stops only the temporary subtree", ctx do
      n = System.unique_integer([:positive])
      names = %{name: :"dex_sup_#{n}", index: :"dex_index_#{n}", bootstrap: :"dex_boot_#{n}"}
      config = config!(ctx, documents: [macus_document()])

      children = [
        {Dex, config: config, name: names.name, index: names.index, bootstrap: names.bootstrap},
        %{id: :sibling, start: {Agent, :start_link, [fn -> :alive end, [name: :"sibling_#{n}"]]}}
      ]

      parent =
        start_supervised!(%{
          id: :parent,
          start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
          type: :supervisor
        })

      assert_receive {:dex_event, "macus", :ready}, 5_000

      sub = Process.whereis(names.name)
      ref = Process.monitor(sub)

      # Exceed the subtree's restart intensity (3 restarts in 5 seconds),
      # killing each restarted index as soon as it is registered.
      kill_restarts(names.index, ref, sub, nil, 10)

      assert_receive {:DOWN, ^ref, :process, ^sub, _reason}, 5_000
      assert Process.alive?(parent)
      assert Agent.get(:"sibling_#{n}", & &1) == :alive
      assert Dex.readiness(names.bootstrap).status == :unavailable
    end
  end

  defp kill_restarts(_index, _ref, _sub, _previous, 0), do: :ok

  defp kill_restarts(index, ref, sub, previous, attempts) do
    receive do
      {:DOWN, ^ref, :process, ^sub, _reason} = down -> send(self(), down)
    after
      0 ->
        case Process.whereis(index) do
          pid when is_pid(pid) and pid != previous ->
            Process.exit(pid, :kill)
            kill_restarts(index, ref, sub, pid, attempts - 1)

          _ ->
            Process.sleep(5)
            kill_restarts(index, ref, sub, previous, attempts)
        end
    end
  end

  defp start_dex!(config) do
    n = System.unique_integer([:positive])
    names = %{name: :"dex_sup_#{n}", index: :"dex_index_#{n}", bootstrap: :"dex_boot_#{n}"}

    start_supervised!(
      {Dex, config: config, name: names.name, index: names.index, bootstrap: names.bootstrap}
    )

    names
  end

  defp config!(ctx, opts) do
    Config.new([index_path: ctx.index_path, owner_uid: ctx.uid] ++ opts)
  end

  defp incus_cassette!(ctx, version, ids) do
    DexFixtures.cassette!(ctx.bundle, "opsmaru_incus", version, [
      DexFixtures.document("opsmaru_incus", ids, version)
    ])
  end

  defp pinned(cassette),
    do: %{cassette: "opsmaru_incus", path: cassette.path, sha256: cassette.sha256}

  defp macus_document do
    %{cassette: "macus", document: DexFixtures.document("macus", ["macus_fixture_status"])}
  end
end
