defmodule Macus.Incus.SharedClientTest do
  # Section 6: Macus consumes the shared opsmaru_incus client and its
  # composite and native operations over its own incus.sock binding
  # (Macus.MCP.IncusHost), with no Incus client of its own. A scripted
  # Cowboy guest records every native request. The index, host
  # configuration and fixture socket are global.
  use ExUnit.Case, async: false

  alias Macus.MCP
  alias Macus.MCP.IncusHost
  alias Macus.TestSupport.{DexFixtures, IncusBackend, NativeBackend}
  alias Opsmaru.Incus
  alias Opsmaru.Incus.Operations.{Composite, Native}
  alias Opsmaru.Incus.{Events, Files, Session, Transfer}

  @owner_key "macus-owner:test"
  @driver Path.expand("../../../../.integration/incus-reference-driver", __DIR__)
  @reference_dir Path.expand("../../reference", __DIR__)
  @op_create "00000000-0000-4000-8000-000000000001"
  @op_snap "00000000-0000-4000-8000-000000000002"
  @op_import "00000000-0000-4000-8000-000000000003"
  @op_backup "00000000-0000-4000-8000-000000000004"
  @op_long "00000000-0000-4000-8000-000000000005"
  @op_console_1 "00000000-0000-4000-8000-000000000006"
  @exec_ok "e0000000-0000-4000-8000-000000000001"
  @exec_hang "e0000000-0000-4000-8000-000000000002"

  # The guest's API extensions: what these operations need, without
  # `warnings` (6.1) or `instance_nbd`.
  @extensions ~w(instances projects project_access profiles_all_projects network
                 networks_all_projects storage storage_api_volume_snapshots storage_buckets
                 storage_volume_full storage_bucket_full clustering certificate_update
                 container_backup custom_volume_backup console container_full
                 instance_get_full api_filtering instance_access image_force_refresh
                 operations_get_query_all_projects resources snapshot_expiry)
  @composite ["incus.read", "incus.write", "incus.exec", "incus.delete"]
  @all @composite ++ Native.scopes()

  setup_all do
    dir = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(dir) end)

    cassette =
      DexFixtures.cassette!(dir, "opsmaru_incus", "0.2.2", [Composite.openapi(), Native.openapi()])

    start_supervised!({Tama.Dex.Index, path: :memory, name: Macus.Dex.Index})
    {:ok, _} = Tama.Dex.import(Macus.Dex.Index, cassette.path, sha256: cassette.sha256)

    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: @reference_dir,
        stderr_to_stdout: true,
        env: [{"GOTOOLCHAIN", "local"}]
      )

    assert status == 0, output
    :ok
  end

  setup do
    root = Path.join("/private/tmp", "mc-sc-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    {:ok, script} = Agent.start_link(fn -> %{} end)

    previous =
      {Application.fetch_env(:macus, :state_dir), Application.fetch_env(:macus, IncusHost)}

    Application.put_env(:macus, :state_dir, root)
    host(owner_uid: File.stat!(root).uid, owner_key: @owner_key, ready: {__MODULE__, :ready?, []})

    on_exit(fn ->
      restore(:state_dir, elem(previous, 0))
      restore(IncusHost, elem(previous, 1))
      File.rm_rf!(root)
    end)

    %{root: root, sock: Path.join(root, "incus.sock"), script: script}
  end

  def ready?, do: true

  defp host(opts), do: Application.put_env(:macus, IncusHost, opts)

  defp put_host(opts),
    do: host(Keyword.merge(Application.get_env(:macus, IncusHost), opts))

  defp restore(key, {:ok, value}), do: Application.put_env(:macus, key, value)
  defp restore(key, :error), do: Application.delete_env(:macus, key)

  describe "6.1 the shared client on Macus's binding" do
    test "operations and the client use the owner's incus.sock and close their connections",
         ctx do
      backend = guest!(ctx)

      %{"result" => %{"item" => server}} = ok!("incus_server_get", %{}, ["incus.read"])
      assert server["api_version"] == "1.0"
      assert_request("GET", "/1.0")

      {:ok, client} = IncusHost.client(context(["incus.read"]))
      assert client.connection.address == ctx.sock
      assert Incus.has_extension?(client, "instances")
      refute Incus.has_extension?(client, "instance_nbd")
      settle(backend)

      # A caller with another owner key gets no client and sends nothing.
      flush_requests()
      assert {:error, _} = IncusHost.client(%{context(["incus.read"]) | owner_key: "other"})
      refute_receive {:incus, _, _, _, _}, 50
    end

    test "a missing API extension fails before the request", ctx do
      guest!(ctx)

      # The fixture guest lacks the `warnings` extension.
      error = failed!("incus_native_get_warnings", %{}, ["incus.native.read"])
      assert error["kind"] == "unsupported_extension"
      refute_received {:incus, _, "/1.0/warnings", _, _}
    end

    test "the local deadline ends the wait and leaves the connection closed", ctx do
      backend = guest!(ctx, %{{"GET", "/1.0/instances/slow"} => {:sleep, 1_500, {:sync, %{}}}})
      put_host(timeout: 300)
      started = System.monotonic_time(:millisecond)
      error = failed!("incus_instance_get", %{"name" => "slow"}, ["incus.read"])
      assert error["kind"] in ["deadline", "timeout"]
      assert System.monotonic_time(:millisecond) - started < 1_200
      settle(backend, 3_000)
    end

    test "Macus has no Incus client of its own" do
      clients =
        for file <- Path.wildcard(Path.expand("../../../lib/**/*.ex", __DIR__)),
            File.read!(file) =~ ~r/Mint\.|:gen_tcp\.connect|:ssl\.connect/,
            do: Path.relative_to(file, Path.expand("../../..", __DIR__))

      # The only HTTP client is the private runtime.sock client.
      assert clients == ["lib/macus/runtime/client.ex"]
    end
  end

  describe "6.2 projects, profiles and access" do
    test "composite and native reads select projects; trust stays the gateway's", ctx do
      guest!(ctx)
      ok!("incus_project_list", %{}, ["incus.read"])
      assert_request("GET", "/1.0/projects")
      ok!("incus_profile_get", %{"name" => "default", "project" => "p1"}, ["incus.read"])
      assert_request("GET", "/1.0/profiles/default", "project=p1")
      ok!("incus_native_get_project_access", %{"name" => "p1"}, ["incus.native.read"])
      assert_request("GET", "/1.0/projects/p1/access")

      # A project outside the host's list is refused before any request.
      put_host(projects: ["default"])
      flush_requests()

      # The binding refuses it; the library reports it without detail.
      assert failed!("incus_profile_list", %{"project" => "p1"}, ["incus.read"])["kind"] ==
               "unauthorized"

      refute_received {:incus, _, _, _, _}

      # Native certificate operations reach the guest's own trust store and
      # never the gateway's.
      put_host(projects: :all)
      ok!("incus_native_get_certificates", %{}, ["incus.native.admin"])
      assert_request("GET", "/1.0/certificates", "recursion=1")
      refute File.exists?(Path.join([ctx.root, "server", "trusted-certificates.json"]))
      assert not_found("incus_native_get_certificates", %{}, ["incus.native.read"])
    end

    test "requests match the official client's, including member selection", ctx do
      guest!(ctx)

      reference =
        requests(fn ->
          refute reference!(ctx, %{"action" => "access"})["error"]
        end)

      shared =
        requests(fn ->
          ok!("incus_project_list", %{}, ["incus.read"])
          ok!("incus_profile_get", %{"name" => "default", "project" => "p1"}, ["incus.read"])
          ok!("incus_native_get_project_access", %{"name" => "p1"}, ["incus.native.read"])
          ok!("incus_native_get_certificates", %{}, ["incus.native.admin"])

          # Member selection belongs to the client: no operation input names a
          # member, so a caller can never retarget the configured backend.
          {:ok, client} = IncusHost.client(context(@all))

          {:ok, _} =
            client |> Incus.member("member-2") |> Incus.call("GetInstance", %{"name" => "c1"}, [])
        end)

      assert shared == reference
      assert {"GET", "/1.0/instances/c1", %{"target" => "member-2"}} in shared

      for {_, %{"post" => operation}} <-
            Map.merge(Composite.openapi()["paths"], Native.openapi()["paths"]),
          input = get_in(operation, ["requestBody", "content", "application/json", "schema"]),
          do: refute(Map.has_key?(input["properties"] || %{}, "target"), operation["operationId"])
    end
  end

  describe "6.3 instances" do
    test "create, read, update, state and delete keep native handles and errors", ctx do
      guest!(ctx, %{
        {"GET", "/1.0/instances/missing"} => {:error, 404, "Instance not found"},
        {"POST", "/1.0/instances"} => {:async, operation(@op_create, "Running", 103)}
      })

      created =
        ok!("incus_instance_create", %{"name" => "c1", "image" => %{"alias" => "debian/12"}}, [
          "incus.write"
        ])

      assert created["result"]["operation_id"] == @op_create
      assert {_, body} = assert_request("POST", "/1.0/instances")
      assert Jason.decode!(body)["name"] == "c1"

      ok!("incus_instance_get", %{"name" => "c1"}, ["incus.read"])
      assert_request("GET", "/1.0/instances/c1")
      ok!("incus_instance_update", %{"name" => "c1", "description" => "web"}, ["incus.write"])
      ok!("incus_instance_state_update", %{"name" => "c1", "action" => "stop"}, ["incus.write"])
      assert_request("PUT", "/1.0/instances/c1/state")
      ok!("incus_instance_delete", %{"name" => "c1", "confirm" => "c1"}, ["incus.delete"])
      assert_request("DELETE", "/1.0/instances/c1")

      missing = failed!("incus_instance_get", %{"name" => "missing"}, ["incus.read"])
      assert %{"kind" => "native", "http_status" => 404} = missing
      assert missing["message"] =~ "Instance not found"

      # Destructive input repeats its target, or nothing is sent.
      assert failed!("incus_instance_delete", %{"name" => "c1", "confirm" => "c2"}, [
               "incus.delete"
             ])["kind"] == "confirmation_required"

      refute_received {:incus, "DELETE", _, _, _}
    end
  end

  describe "6.4 snapshots" do
    test "snapshot and restore keep operation identity, conflicts and confirmation", ctx do
      guest!(ctx, %{
        {"POST", "/1.0/instances/c1/snapshots"} => {:async, operation(@op_snap, "Running", 103)},
        {"PUT", "/1.0/instances/c1"} => {:error, 409, "Instance is busy"}
      })

      created =
        ok!("incus_instance_snapshot_create", %{"instance" => "c1", "name" => "s1"}, [
          "incus.write"
        ])

      assert created["result"]["operation_id"] == @op_snap
      ok!("incus_instance_snapshot_list", %{"instance" => "c1"}, ["incus.read"])

      conflict =
        failed!(
          "incus_instance_snapshot_restore",
          %{"instance" => "c1", "snapshot" => "s1", "confirm" => "c1/s1"},
          ["incus.delete"]
        )

      assert %{"kind" => "native", "http_status" => 409} = conflict
      assert {_, body} = assert_request("PUT", "/1.0/instances/c1")
      assert Jason.decode!(body)["restore"] == "s1"

      assert failed!(
               "incus_instance_snapshot_delete",
               %{"instance" => "c1", "name" => "s1", "confirm" => "c1"},
               ["incus.delete"]
             )["kind"] == "confirmation_required"

      refute_received {:incus, "DELETE", _, _, _}
    end
  end

  describe "6.5 images" do
    test "aliases and metadata through operations; import and export stream through the client",
         ctx do
      guest!(ctx, %{
        {"GET", "/1.0/images/abc/export"} =>
          {:stream, %{"content-type" => "application/octet-stream"}, ["IMG", "DATA"]},
        {"POST", "/1.0/images"} => {:async, operation(@op_import, "Running", 103)}
      })

      ok!("incus_image_alias_list", %{}, ["incus.read"])
      assert_request("GET", "/1.0/images/aliases", "recursion=1")

      ok!("incus_native_create_image_alias", %{"body" => %{"name" => "web", "target" => "abc"}}, [
        "incus.native.write"
      ])

      assert_request("POST", "/1.0/images/aliases")

      {:ok, client} = IncusHost.client(context(@all))
      parent = self()
      {:ok, _} = Transfer.download(client, "/1.0/images/abc/export", &send_chunk(parent, &1))
      assert collect_chunks() == "IMGDATA"

      {:ok, imported} =
        Transfer.upload(client, "/1.0/images", ["tarball-", "bytes"], [
          {"content-type", "application/octet-stream"}
        ])

      assert imported.http_status == 202
      assert {_, "tarball-bytes"} = assert_request("POST", "/1.0/images")
    end
  end

  describe "6.6 networks and cluster" do
    test "network and cluster reads stay on the one configured backend", ctx do
      guest!(ctx)
      ok!("incus_network_list", %{}, ["incus.read"])
      assert_request("GET", "/1.0/networks", "recursion=1")
      ok!("incus_native_get_cluster", %{}, ["incus.native.admin"])
      assert_request("GET", "/1.0/cluster")
      ok!("incus_native_get_cluster_members", %{}, ["incus.native.admin"])
      assert_request("GET", "/1.0/cluster/members", "recursion=1")

      # No input selects another backend: a URL or socket is rejected.
      flush_requests()

      for field <- ["url", "socket", "remote"] do
        assert %{"error" => %{"dispatched" => false}} =
                 run("incus_network_list", %{field => "https://10.0.2.15:8443"}, ["incus.read"])
      end

      refute_received {:incus, _, _, _, _}
    end
  end

  describe "6.7 storage" do
    test "pools, volumes, volume snapshots and buckets keep native types and errors", ctx do
      guest!(ctx, %{
        {"GET", "/1.0/storage-pools/missing"} => {:error, 404, "Storage pool not found"}
      })

      ok!("incus_storage_volume_list", %{"pool" => "default"}, ["incus.read"])
      assert_request("GET", "/1.0/storage-pools/default/volumes", "recursion=1")

      ok!(
        "incus_native_get_storage_pool_volume_snapshots",
        %{"pool" => "default", "volumeType" => "custom", "volumeName" => "data"},
        ["incus.native.read"]
      )

      assert_request("GET", "/1.0/storage-pools/default/volumes/custom/data/snapshots")

      ok!(
        "incus_native_get_storage_pool_bucket",
        %{"poolName" => "default", "bucketName" => "b1"},
        ["incus.native.read"]
      )

      assert_request("GET", "/1.0/storage-pools/default/buckets/b1")

      assert %{"kind" => "native", "http_status" => 404} =
               failed!("incus_storage_pool_get", %{"name" => "missing"}, ["incus.read"])

      # Bucket keys carry S3 credentials; no operation reads or writes them.
      credentials =
        for %{"method" => method, "rule" => "remote_backend_or_credential"} <-
              Native.unavailable(),
            do: method

      for method <-
            ~w(GetStoragePoolBucketKey CreateStoragePoolBucketKey UpdateStoragePoolBucketKey),
          do: assert(method in credentials)
    end
  end

  describe "6.8 files, backups and native upgrades" do
    test "file and backup bytes move through the shared client", ctx do
      guest!(ctx, %{
        {"GET", "/1.0/instances/c1/files"} =>
          {:binary, 200,
           %{
             "content-type" => "application/octet-stream",
             "x-incus-type" => "file",
             "x-incus-uid" => "0",
             "x-incus-gid" => "0",
             "x-incus-mode" => "0644"
           }, <<0, 255, "file">>},
        {"POST", "/1.0/instances/c1/files"} => {:sync, %{}},
        {"POST", "/1.0/instances/c1/backups"} => {:async, operation(@op_backup, "Running", 103)},
        {"GET", "/1.0/instances/c1/backups/b1/export"} =>
          {:stream, %{"content-type" => "application/octet-stream"}, ["back", "up"]}
      })

      {:ok, client} = IncusHost.client(context(@all))
      parent = self()
      {:ok, _} = Files.read(client, "c1", "/etc/motd", &send_chunk(parent, &1))
      assert collect_chunks() == <<0, 255, "file">>
      assert_request("GET", "/1.0/instances/c1/files", "path=%2Fetc%2Fmotd")

      {:ok, _} = Files.create(client, "c1", "/tmp/x", [<<1, 2>>, <<3>>], mode: 0o600)
      assert {_, <<1, 2, 3>>} = assert_request("POST", "/1.0/instances/c1/files")

      backup =
        ok!(
          "incus_native_create_instance_backup",
          %{"instanceName" => "c1", "body" => %{"name" => "b1"}},
          ["incus.native.write"]
        )

      assert backup["result"]["operation_id"] == @op_backup
      {:ok, _} = Files.backup_download(client, "c1", "b1", &send_chunk(parent, &1))
      assert collect_chunks() == "backup"
    end

    @tag protocol: "nbd"
    test "the shared NBD client upgrades and relays bytes over Macus's binding", ctx do
      start_supervised!(
        {NativeBackend, %{path: ctx.sock, protocol: "nbd", observer: self(), initial: <<7, 8>>}}
      )

      {:ok, client} = IncusHost.client(context(@all))
      {:ok, channel} = Incus.nbd(client, "c1")
      assert_receive {:backend_request, head}
      assert head =~ "GET /1.0/instances/c1/nbd HTTP/1.1"
      assert {:ok, <<7, 8>>} = Opsmaru.Incus.RawChannel.recv(channel, 2_000)
      :ok = Opsmaru.Incus.RawChannel.send_data(channel, <<0, 255, 1>>)
      assert {:ok, <<0, 255, 1>>} = Opsmaru.Incus.RawChannel.recv(channel, 2_000)
      :ok = Opsmaru.Incus.RawChannel.close(channel)
      assert_receive {:backend_closed, _}, 2_000
    end
  end

  describe "6.9 operations and events" do
    test "waits time out locally, cancellation is explicit and events are bounded", ctx do
      guest!(ctx, %{
        {"GET", "/1.0/operations/#{@op_long}"} => {:sync, operation(@op_long, "Running", 103)},
        {"GET", "/1.0/operations/#{@op_long}/wait"} =>
          {:sleep, 1_200, {:sync, operation(@op_long, "Running", 103)}},
        {"DELETE", "/1.0/operations/#{@op_long}"} => {:sync, %{}}
      })

      waited =
        ok!("incus_operation_wait", %{"operation_id" => @op_long, "wait_seconds" => 1}, [
          "incus.read"
        ])

      assert waited["result"]["status"] in ["running", "uncertain"]
      refute_received {:incus, "DELETE", "/1.0/operations/#{@op_long}", _, _}

      ok!("incus_operation_cancel", %{"operation_id" => @op_long}, ["incus.write"])
      assert_request("DELETE", "/1.0/operations/#{@op_long}")

      {:ok, client} = IncusHost.client(context(@all))
      {:ok, events} = Events.subscribe(client, types: ["lifecycle"])
      assert_request("GET", "/1.0/events", "type=lifecycle")
      {:ok, event} = Events.next(events, 2_000)
      assert event.data["metadata"]["action"] == "instance-started"
      :ok = Events.close(events)
      assert_receive {:incus_ws_closed, _}, 2_000
    end

    test "an event subscription that falls behind reports overflow and closes", ctx do
      guest!(ctx)
      {:ok, client} = IncusHost.client(context(@all))
      {:ok, events} = Events.subscribe(client, types: ["overflow"])
      # The guest sends 256 events at once; the subscription holds 64.
      Process.sleep(500)
      {delivered, {:error, %Opsmaru.Incus.Error{kind: kind}}} = drain(events, 0)
      assert delivered < 256
      # The channel tells its owner why it ended; a later read finds it closed.
      assert kind in [:overflow, :channel_closed]
      ref = events.ref
      assert_received {^ref, :error, %Opsmaru.Incus.Error{kind: :overflow}}
      assert_receive {:incus_ws_closed, _}, 2_000
    end
  end

  describe "6.10 exec and console" do
    test "exec returns exit status and bounded output and closes every channel", ctx do
      guest!(ctx, %{
        {"POST", "/1.0/instances/c1/exec"} => {:async, exec_operation(IncusBackend.exec_ok())},
        {"GET", "/1.0/operations/#{IncusBackend.exec_ok()}"} =>
          {:sync,
           Map.merge(exec_operation(IncusBackend.exec_ok(), "Success", 200), %{
             "metadata" => %{"return" => 3}
           })}
      })

      %{"result" => result} =
        ok!(
          "incus_instance_exec",
          %{"instance" => "c1", "command" => ["sh", "-c", "cat"], "stdin" => "input"},
          ["incus.exec"]
        )

      assert result["exit_status"] == 3, inspect(result)
      assert result["stdout"] == "hello world\n"
      assert result["stderr"] == "warn\n"
      assert result["timed_out"] == false
      assert_receive {:exec_stdin, "input"}, 2_000
      {_, body} = assert_request("POST", "/1.0/instances/c1/exec")
      assert %{"interactive" => false, "wait-for-websocket" => true} = Jason.decode!(body)

      for secret <- ["s0", "s1", "s2", "sc"],
          do: assert_receive({:incus_channel_closed, @exec_ok, ^secret}, 2_000)
    end

    test "an exec past its duration is signalled over the control channel", ctx do
      guest!(ctx, %{
        {"POST", "/1.0/instances/c1/exec"} => {:async, exec_operation(IncusBackend.exec_hang())},
        {"GET", "/1.0/operations/#{IncusBackend.exec_hang()}"} =>
          {:sync,
           Map.merge(exec_operation(IncusBackend.exec_hang(), "Success", 200), %{
             "metadata" => %{"return" => 137}
           })}
      })

      %{"result" => result} =
        ok!(
          "incus_instance_exec",
          %{"instance" => "c1", "command" => ["sleep", "60"], "timeout_seconds" => 1},
          ["incus.exec"]
        )

      assert result["timed_out"] == true
      assert result["stdout"] == "partial"
      assert_receive {:incus_control, @exec_hang, %{"command" => "signal", "signal" => 9}}, 3_000
    end

    test "the shared console client attaches, sends terminal controls and detaches", ctx do
      guest!(ctx, %{
        {"POST", "/1.0/instances/c1/console"} =>
          {:async,
           Map.merge(operation(@op_console_1, "Running", 103), %{
             "class" => "websocket",
             "metadata" => %{"fds" => %{"0" => "c0", "control" => "cc"}}
           })}
      })

      {:ok, client} = IncusHost.client(context(@all))
      {:ok, console} = Session.console(client, "c1", %{"width" => 80, "height" => 24})
      :ok = Session.resize(console, 100, 40)

      assert_receive {:incus_control, @op_console_1,
                      %{"command" => "window-resize", "args" => %{"width" => "100"}}},
                     2_000

      :ok = Session.input(console, "ls\r")
      assert {:ok, {:binary, "ls\r"}} = Session.output(console, "0", 2_000)
      :ok = Session.close(console)
      assert_receive {:incus_channel_closed, @op_console_1, "cc"}, 2_000
      assert_receive {:incus_channel_closed, @op_console_1, "c0"}, 2_000
    end
  end

  describe "6.11 migration and copy" do
    test "nothing that names another server is exported as an operation" do
      unavailable = Enum.map(Native.unavailable(), & &1["method"])

      for method <-
            ~w(MigrateInstance MigrateInstanceSnapshot MigrateStoragePoolVolume ExportImage),
          do: assert(method in unavailable)

      composite = Enum.map(Composite.unavailable(), & &1["name"])
      assert "incus_instance_copy" in composite and "incus_instance_move" in composite
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp guest!(ctx, routes \\ %{}) do
    Agent.update(ctx.script, fn _ -> routes end)
    script = ctx.script

    IncusBackend.start!(ctx.sock, self(),
      extensions: @extensions,
      script: fn request ->
        Agent.get(script, &Map.get(&1, {request.method, request.path})) || default(request)
      end
    )
  end

  # Native-looking answers for anything not scripted.
  defp default(%{method: "GET", path: "/1.0"}), do: nil
  defp default(%{method: "GET", path: "/1.0/events"}), do: nil

  defp default(%{method: "GET", path: "/1.0/operations/" <> rest}) do
    [id | _] = String.split(rest, "/")
    {:sync, operation(id, "Success", 200)}
  end

  defp default(%{method: "GET", qs: qs, path: path}) do
    cond do
      qs =~ "recursion=1" or plural?(path) -> {:sync, []}
      true -> {:sync, 200, item(path), %{"etag" => ~s("etag")}}
    end
  end

  defp default(%{method: method}) when method in ["POST", "PUT", "PATCH", "DELETE"],
    do: {:async, operation(uuid(), "Running", 103)}

  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp plural?(path) do
    last = path |> String.split("/") |> List.last()

    last in ~w(instances projects profiles networks certificates operations snapshots
               volumes members aliases images storage-pools buckets backups warnings groups access)
  end

  defp item(path) do
    name = path |> String.split("/") |> List.last()

    %{
      "name" => name,
      "status" => "Running",
      "status_code" => 103,
      "type" => "container",
      "description" => "",
      "config" => %{},
      "devices" => %{},
      "profiles" => ["default"],
      "used_by" => [],
      "project" => "default"
    }
  end

  defp operation(id, status, code) do
    %{
      "id" => id,
      "class" => "task",
      "description" => "Fixture operation",
      "created_at" => "2026-11-18T00:00:00Z",
      "updated_at" => "2026-11-18T00:00:00Z",
      "status" => status,
      "status_code" => code,
      "resources" => %{"instances" => ["/1.0/instances/c1"]},
      "metadata" => %{},
      "may_cancel" => true,
      "err" => "",
      "location" => "none"
    }
  end

  defp exec_operation(id, status \\ "Running", code \\ 103) do
    Map.merge(operation(id, status, code), %{
      "class" => "websocket",
      "metadata" => %{"fds" => %{"0" => "s0", "1" => "s1", "2" => "s2", "control" => "sc"}}
    })
  end

  defp context(scopes) do
    %TamaMCP.Context{
      request_id: 1,
      principal: "owner",
      owner_key: @owner_key,
      claims: %{},
      scopes: scopes
    }
  end

  defp run(operation_id, input, scopes) do
    cassette = "opsmaru_incus"

    MCP.execute(
      %{"cassette" => cassette, "operation_id" => operation_id, "input" => input},
      context(scopes)
    )
  end

  defp ok!(operation_id, input, scopes) do
    response = run(operation_id, input, scopes)
    refute Map.has_key?(response, "error"), inspect(response)
    refute Map.has_key?(response, "operation_error"), inspect(response)
    response
  end

  defp failed!(operation_id, input, scopes) do
    response = run(operation_id, input, scopes)

    case response do
      %{"operation_error" => %{"error" => error}, "dispatched" => true} -> error
      other -> flunk("expected an operation error, got #{inspect(other)}")
    end
  end

  defp not_found(operation_id, input, scopes),
    do: match?(%{"error" => %{"kind" => "not_found"}}, run(operation_id, input, scopes))

  defp drain(events, count) do
    case Events.next(events, 1_000) do
      {:ok, _event} -> drain(events, count + 1)
      other -> {count, other}
    end
  end

  # The guest requests made by `fun`, without discovery, as {method, path,
  # query}.
  defp requests(fun) do
    flush_requests()
    fun.()
    collect_requests([])
  end

  defp collect_requests(acc) do
    receive do
      {:incus, "GET", "/1.0", _, _} ->
        collect_requests(acc)

      {:incus, method, path, qs, _} ->
        collect_requests([{method, path, URI.decode_query(qs)} | acc])

      {:incus_request_body, _, _, _} ->
        collect_requests(acc)
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp reference!(ctx, fields) do
    path = Path.join(ctx.root, "reference-#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(Map.put(fields, "socket", ctx.sock)))
    File.chmod!(path, 0o600)
    {output, status} = System.cmd(@driver, [path], stderr_to_stdout: true)
    File.rm!(path)
    assert status == 0, output
    Jason.decode!(output)
  end

  defp flush_requests do
    receive do
      {:incus, _, _, _, _} -> flush_requests()
      {:incus_request_body, _, _, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  # The next recorded request with this method and path (and query, when
  # given); returns {qs, body}. Bodies are recorded separately by scripted
  # routes, so the body is read back from the request log.
  defp assert_request(method, path, qs \\ nil) do
    receive do
      {:incus, ^method, ^path, seen, _headers} when is_nil(qs) or seen == qs ->
        body =
          receive do
            {:incus_request_body, ^method, ^path, body} -> body
          after
            0 -> ""
          end

        {seen, body}
    after
      2_000 -> flunk("no #{method} #{path} #{qs} request")
    end
  end

  defp settle(backend, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      IncusBackend.open_connections(backend) == 0 or
        (System.monotonic_time(:millisecond) < deadline and (Process.sleep(20) || false))
    end)
    |> Enum.find(& &1)

    assert IncusBackend.open_connections(backend) == 0
  end

  defp send_chunk(parent, chunk) do
    send(parent, {:chunk, chunk})
    :ok
  end

  defp collect_chunks(acc \\ "") do
    receive do
      {:chunk, chunk} -> collect_chunks(acc <> chunk)
    after
      100 -> acc
    end
  end
end
