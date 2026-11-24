defmodule Macus.Proxy.AccessLogTest do
  # Drives the access log with `:telemetry.execute/3` and the stop metadata
  # planned by the shared library's add-gateway-exchange-telemetry change.
  # Global logger and telemetry state.
  use ExUnit.Case, async: false

  import Bitwise
  import ExUnit.CaptureLog

  alias Macus.Proxy.AccessLog

  @event [:opsmaru_incus, :gateway, :exchange, :stop]
  @fingerprint String.duplicate("3f9a", 16)
  @ended ~U[2026-11-23 10:15:02.412345Z]
  @id "9c1f6a02b47de853-1"
  @keys ~w(v id time protocol method path project target all_projects operation peer certificate
           admitted_as status outcome reason duration_ms request_bytes response_bytes)

  setup do
    root = Path.join(System.tmp_dir!(), "macus-access-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    state_dir = Path.join(root, "state")
    File.mkdir!(state_dir)
    File.chmod!(state_dir, 0o700)
    %File.Stat{uid: uid} = File.lstat!(state_dir)
    on_exit(fn -> File.rm_rf!(root) end)

    logs = Path.join(state_dir, "logs")
    %{state_dir: state_dir, uid: uid, logs: logs, log_file: Path.join(logs, "gateway-access.log")}
  end

  defp start(ctx, opts \\ []) do
    start_supervised!({AccessLog, [state_dir: ctx.state_dir, uid: ctx.uid] ++ opts})
  end

  defp metadata(fields) do
    Map.merge(
      %{
        telemetry_span_context: make_ref(),
        host: Macus.Proxy.Host,
        protocol: :http,
        method: "GET",
        path: "/1.0/instances",
        project: nil,
        target: nil,
        all_projects: false,
        operation: nil,
        peer_address: {192, 168, 1, 20},
        peer_port: 51_422,
        peer_fingerprint: @fingerprint,
        admitted_as: :caller,
        status: 200,
        outcome: :ok,
        reason: nil
      },
      Map.new(fields)
    )
  end

  defp measurements(fields \\ []) do
    Map.merge(
      %{
        duration: System.convert_time_unit(12, :millisecond, :native),
        request_bytes: 0,
        response_bytes: 1834
      },
      Map.new(fields)
    )
  end

  defp emit(meta, meas \\ measurements()), do: :telemetry.execute(@event, meas, meta)

  defp sync, do: :ok = :logger_std_h.filesync(AccessLog.handler_id())

  defp lines(path) do
    sync()

    case File.read(path) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  defp records(path), do: Enum.map(lines(path), &Jason.decode!/1)

  defp keys(line) do
    Regex.scan(~r/"([a-z_]+)":/, line, capture: :all_but_first) |> List.flatten()
  end

  defmodule Probe do
    def log(%{msg: {:string, text}}, %{config: %{pid: pid}}),
      do: send(pid, {:probe, IO.chardata_to_string(text)})

    def log(_event, _config), do: :ok
  end

  describe "line/5" do
    test "has the documented keys in order and the documented values" do
      line = AccessLog.line(@id, measurements(), metadata([]), @ended)

      assert line ==
               ~s({"v":1,"id":"9c1f6a02b47de853-1","time":"2026-11-23T10:15:02.412Z",) <>
                 ~s("protocol":"http","method":"GET",) <>
                 ~s("path":"/1.0/instances","project":null,"target":null,"all_projects":false,) <>
                 ~s("operation":null,"peer":"192.168.1.20:51422","certificate":"#{@fingerprint}",) <>
                 ~s("admitted_as":"caller","status":200,"outcome":"ok","reason":null,) <>
                 ~s("duration_ms":12,"request_bytes":0,"response_bytes":1834})
    end

    test "brackets IPv6 peers, from tuples and strings" do
      ipv6 = metadata(peer_address: {0, 0, 0, 0, 0, 0, 0, 1}, peer_port: 8443)

      assert Jason.decode!(AccessLog.line(@id, measurements(), ipv6, @ended))["peer"] ==
               "[::1]:8443"

      string = metadata(peer_address: "fe80::1", peer_port: 1)

      assert Jason.decode!(AccessLog.line(@id, measurements(), string, @ended))["peer"] ==
               "[fe80::1]:1"

      none = metadata(peer_address: nil, peer_port: nil)
      assert Jason.decode!(AccessLog.line(@id, measurements(), none, @ended))["peer"] == nil
    end

    test "ignores unknown metadata and never writes non-scalar values" do
      meta =
        metadata(
          authorization: "Bearer macus.0011223344556677.secret",
          query: "secret=operation-secret",
          headers: [{"authorization", "x"}],
          grant: %{token: "t"},
          project: %{nested: true},
          path: <<0xFF, 0xFE>>
        )

      line = AccessLog.line(@id, measurements(), meta, @ended)
      assert keys(line) == @keys
      refute line =~ "secret"
      refute line =~ "authorization"
      refute line =~ "Bearer"
      decoded = Jason.decode!(line)
      assert decoded["project"] == nil
      assert decoded["path"] == nil
    end

    test "converts UTC offsets and missing measurements" do
      line = AccessLog.line(@id, %{}, metadata([]), ~U[2026-11-23 10:15:02Z])
      decoded = Jason.decode!(line)
      assert decoded["time"] == "2026-11-23T10:15:02.000Z"
      assert decoded["duration_ms"] == nil
      assert decoded["request_bytes"] == nil
    end

    test "appends dropped_before only after drops" do
      refute AccessLog.line(@id, measurements(), metadata([]), @ended, 0) =~ "dropped_before"
      line = AccessLog.line(@id, measurements(), metadata([]), @ended, 7)
      assert keys(line) == @keys ++ ["dropped_before"]
      assert Jason.decode!(line)["dropped_before"] == 7
    end
  end

  describe "recording" do
    test "writes one line per exchange kind, with the planned metadata", ctx do
      start(ctx)

      cases = [
        relayed_read: metadata([]),
        relayed_mutation:
          metadata(
            method: "POST",
            path: "/1.0/instances",
            project: "web",
            status: 202,
            operation: "/1.0/operations/0b4c"
          ),
        refused_untrusted:
          metadata(
            admitted_as: nil,
            status: 403,
            outcome: :not_sent,
            reason: :unauthorized
          ),
        anonymous_discovery:
          metadata(path: "/1.0", admitted_as: :anonymous, peer_fingerprint: nil),
        trust_action:
          metadata(method: "POST", path: "/1.0/certificates", admitted_as: :anonymous),
        operation_peer:
          metadata(
            protocol: :websocket,
            path: "/1.0/operations/0b4c/websocket",
            operation: "0b4c",
            admitted_as: :operation_peer,
            peer_fingerprint: nil,
            status: 101
          ),
        image_peer:
          metadata(
            path: "/1.0/images/abc/export",
            admitted_as: :image_peer,
            peer_fingerprint: nil
          ),
        websocket:
          metadata(
            protocol: :websocket,
            path: "/1.0/events",
            status: 101,
            outcome: :sent,
            reason: :revoked
          ),
        raw_upgrade:
          metadata(
            protocol: :raw,
            path: "/1.0/instances/web/sftp",
            status: 101
          )
      ]

      for {_name, meta} <- cases, do: emit(meta)

      written = lines(ctx.log_file)
      assert length(written) == length(cases)
      assert Enum.all?(written, &(keys(&1) == @keys))

      # One boot value for the run, and SEQ counting the records from 1.
      ids = Enum.map(written, &(Jason.decode!(&1)["id"] |> String.split("-")))
      assert [[boot, "1"] | _] = ids
      assert boot =~ ~r/\A[0-9a-f]{16}\z/
      assert ids == for(n <- 1..length(cases), do: [boot, Integer.to_string(n)])

      [read, mutation, refused, anonymous, trust, operation, image, ws, raw] =
        Enum.map(written, &Jason.decode!/1)

      assert %{"method" => "GET", "status" => 200, "certificate" => @fingerprint} = read
      assert %{"method" => "POST", "project" => "web", "status" => 202} = mutation

      assert %{"status" => 403, "outcome" => "not_sent", "reason" => "unauthorized"} = refused
      assert refused["admitted_as"] == nil and refused["certificate"] == @fingerprint
      assert %{"admitted_as" => "anonymous", "certificate" => nil} = anonymous
      assert %{"path" => "/1.0/certificates", "admitted_as" => "anonymous"} = trust
      assert %{"admitted_as" => "operation_peer", "operation" => "0b4c"} = operation
      assert %{"admitted_as" => "image_peer"} = image
      assert %{"protocol" => "websocket", "reason" => "revoked", "outcome" => "sent"} = ws
      assert %{"protocol" => "raw", "status" => 101} = raw
      assert %{errors: 0, dropped: 0} = AccessLog.stats()
    end

    test "a handler error is rescued, counted and leaves the handler attached", ctx do
      start(ctx)
      emit(metadata([]), measurements(duration: "not a time"))
      assert %{errors: 1} = AccessLog.stats()
      assert Enum.any?(:telemetry.list_handlers(@event), &(&1.id == {AccessLog, :stop}))

      emit(metadata([]))
      assert [_one] = lines(ctx.log_file)
    end

    test "access lines never reach the default handler", ctx do
      start(ctx)
      {:ok, default} = :logger.get_handler_config(:default)
      assert {:macus_access, AccessLog.default_filter()} in default.filters

      event = %{level: :info, msg: {:string, "x"}, meta: %{domain: [:macus, :access]}}
      {filter, args} = AccessLog.default_filter()
      assert filter.(event, args) == :stop

      # A handler with the default handler's filters sees other lines but
      # no access line, which only the access handler writes.
      :ok =
        :logger.add_handler(:access_probe, __MODULE__.Probe, %{
          config: %{pid: self()},
          filters: default.filters,
          filter_default: default.filter_default
        })

      on_exit(fn -> :logger.remove_handler(:access_probe) end)
      emit(metadata(path: "/1.0/marker-path"))
      capture_log(fn -> :logger.warning("other line") end)
      assert_receive {:probe, "other line"}
      refute_received {:probe, _}
      assert [line] = lines(ctx.log_file)
      assert line =~ "marker-path"
    end

    test "stops recording when stopped", ctx do
      pid = start(ctx)
      :ok = stop_supervised(AccessLog)
      refute Process.alive?(pid)
      assert :telemetry.list_handlers(@event) == []
      assert {:error, {:not_found, :macus_access}} = :logger.get_handler_config(:macus_access)
    end
  end

  describe "writer" do
    test "rotates at the size limit and removes the oldest archive", ctx do
      start(ctx, max_bytes: 1_000, max_files: 2)

      for n <- 1..40 do
        emit(metadata(path: "/1.0/instances/n#{n}"))
        sync()
      end

      assert File.exists?(ctx.log_file)
      assert File.exists?(ctx.log_file <> ".0")
      assert File.exists?(ctx.log_file <> ".1")
      refute File.exists?(ctx.log_file <> ".2")

      paths =
        [ctx.log_file <> ".1", ctx.log_file <> ".0", ctx.log_file]
        |> Enum.flat_map(&records/1)
        |> Enum.map(& &1["path"])

      # The newest lines are kept in order across the archives; the oldest
      # archive beyond the count was removed.
      assert List.last(paths) == "/1.0/instances/n40"
      refute "/1.0/instances/n1" in paths

      assert paths ==
               Enum.sort_by(
                 paths,
                 &(&1 |> String.split("n") |> List.last() |> String.to_integer())
               )

      assert File.stat!(ctx.log_file).size <= 1_000 + 400
    end

    test "reopens the file after it is deleted", ctx do
      start(ctx)
      emit(metadata(path: "/1.0/first"))
      assert [_] = lines(ctx.log_file)
      File.rm!(ctx.log_file)

      emit(metadata(path: "/1.0/second"))
      assert [line] = lines(ctx.log_file)
      assert line =~ "/1.0/second"
    end

    test "under umask 077 the file and its archives are 0600" do
      # `rel/env.sh.eex` sets the umask for the release; logger_std_h
      # creates the files with it. Run the handler in a fresh VM under it.
      template = File.read!(Path.expand("../../../rel/env.sh.eex", __DIR__))
      assert template |> String.split("\n") |> Enum.member?("umask 077")

      root = Path.join(System.tmp_dir!(), "macus-umask-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      File.chmod!(root, 0o700)
      on_exit(fn -> File.rm_rf!(root) end)
      file = Path.join(root, "gateway-access.log")
      erl = Path.join([:code.root_dir(), "bin", "erl"])

      eval = """
      ok = logger:add_handler(t, logger_std_h, \#{config => \#{file => "#{file}", max_no_bytes => 100, max_no_files => 2}, formatter => {logger_formatter, \#{template => [msg, "\\n"]}}}),
      [logger:notice(lists:duplicate(80, $x)) || _ <- lists:seq(1, 6)],
      logger_std_h:filesync(t),
      halt().
      """

      {_, 0} =
        System.cmd("/bin/sh", ["-c", "umask 077 && exec \"$0\" -noshell -eval \"$1\"", erl, eval])

      for path <- [file, file <> ".0", file <> ".1"] do
        assert band(File.stat!(path).mode, 0o777) == 0o600, path
      end
    end

    test "drops records while the writer is stalled and marks the next line", ctx do
      start(ctx, drop_qlen: 5)
      writer = Process.whereis(:logger_std_h_macus_access)
      parent = self()

      :telemetry.attach(
        "drop-test",
        [:macus, :access_log, :dropped],
        fn _, %{count: 1}, _, _ -> send(parent, :dropped) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("drop-test") end)

      :ok = :sys.suspend(writer)
      started = System.monotonic_time(:millisecond)
      for n <- 1..12, do: emit(metadata(path: "/1.0/stalled/#{n}"))
      # Emitting never waited for the stalled writer.
      assert System.monotonic_time(:millisecond) - started < 1_000
      :ok = :sys.resume(writer)

      assert %{dropped: 7, pending: 7} = AccessLog.stats()
      for _ <- 1..7, do: assert_received(:dropped)

      emit(metadata(path: "/1.0/resumed"))
      written = records(ctx.log_file)
      assert length(written) == 6
      assert Enum.all?(Enum.take(written, 5), &(not Map.has_key?(&1, "dropped_before")))
      assert %{"path" => "/1.0/resumed", "dropped_before" => 7} = List.last(written)
      assert %{dropped: 7, pending: 0} = AccessLog.stats()

      # Dropped records took a SEQ, so the gap equals the marker.
      seqs = Enum.map(written, &(&1["id"] |> String.split("-") |> List.last()))
      assert seqs == ~w(1 2 3 4 5 13)

      emit(metadata(path: "/1.0/after"))
      refute Map.has_key?(List.last(records(ctx.log_file)), "dropped_before")
    end
  end

  describe "record identity" do
    test "ids are unique across a restart and SEQ restarts at 1", ctx do
      start(ctx)
      for _ <- 1..3, do: emit(metadata([]))
      first = Enum.map(records(ctx.log_file), & &1["id"])
      :ok = stop_supervised(AccessLog)

      start(ctx)
      for _ <- 1..3, do: emit(metadata([]))
      all = Enum.map(records(ctx.log_file), & &1["id"])
      second = all -- first

      assert length(all) == 6
      assert Enum.uniq(all) == all
      [[boot_a, "1"], [boot_a, "2"], [boot_a, "3"]] = Enum.map(first, &String.split(&1, "-"))
      [[boot_b, "1"], [boot_b, "2"], [boot_b, "3"]] = Enum.map(second, &String.split(&1, "-"))
      assert boot_a != boot_b
    end
  end

  describe "location" do
    test "creates STATE/logs 0700 only when absent", ctx do
      start(ctx)
      assert %File.Stat{type: :directory, mode: mode} = File.lstat!(ctx.logs)
      assert band(mode, 0o777) == 0o700
    end

    test "an unsafe directory disables the log with one error and does not stop serving", ctx do
      File.mkdir!(ctx.logs)
      File.chmod!(ctx.logs, 0o755)

      log =
        capture_log(fn ->
          children = [
            {AccessLog, [state_dir: ctx.state_dir, uid: ctx.uid]},
            {Agent, fn -> :serving end}
          ]

          {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

          assert [{Agent, agent, _, _}] =
                   Supervisor.which_children(sup) |> Enum.filter(&is_pid(elem(&1, 1)))

          assert Agent.get(agent, & &1) == :serving
          Supervisor.stop(sup)
        end)

      assert length(Regex.scan(~r/Gateway access log disabled/, log)) == 1
      assert band(File.lstat!(ctx.logs).mode, 0o777) == 0o755
      assert :telemetry.list_handlers(@event) == []
      refute File.exists?(ctx.log_file)
    end

    test "a log file that is a symbolic link disables the log", ctx do
      File.mkdir!(ctx.logs)
      File.chmod!(ctx.logs, 0o700)
      File.ln_s!("/dev/null", ctx.log_file)

      log =
        capture_log(fn ->
          assert :ignore = AccessLog.start_link(state_dir: ctx.state_dir, uid: ctx.uid)
        end)

      assert log =~ "Gateway access log disabled"
      assert :telemetry.list_handlers(@event) == []
    end

    test "an unwritable directory disables the log", ctx do
      File.mkdir!(ctx.logs)
      File.chmod!(ctx.logs, 0o500)
      on_exit(fn -> File.chmod(ctx.logs, 0o700) end)

      log =
        capture_log(fn ->
          assert :ignore = AccessLog.start_link(state_dir: ctx.state_dir, uid: ctx.uid)
        end)

      assert log =~ "Gateway access log disabled"
    end
  end
end
