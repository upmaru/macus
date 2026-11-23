defmodule Macus.Incus.ClientWorkersTest do
  # Task 1.7: the explicit private backend for :opsmaru_incus and the
  # optional host-supervised client workers. Stops and starts the
  # :opsmaru_incus application and changes global configuration.
  use ExUnit.Case, async: false

  alias Macus.MCP.IncusHost
  alias Macus.TestSupport.{HTTPFixture, IncusBackend}
  alias Opsmaru.Incus

  @owner_key "macus-owner:workers"

  # Files the Swift runtime keeps in its state directory, standing in for
  # a ready VM's state and the acceptance workload marker.
  @swift_files %{
    "config.json" => ~s({"channel":"lts"}),
    "daemon.lock" => "",
    "bootstrap-journal.json" => ~s({"state":"ready"}),
    "data.raw" => :binary.copy(<<0>>, 4096),
    "workload-marker" => "kept"
  }

  setup do
    root = Path.join("/private/tmp", "mc-cw-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    for {name, content} <- @swift_files, do: File.write!(Path.join(root, name), content)
    {:ok, ready} = Agent.start_link(fn -> true end)

    previous = %{
      state_dir: Application.fetch_env(:macus, :state_dir),
      host: Application.fetch_env(:macus, IncusHost),
      incus: Application.fetch_env(:macus, Macus.Incus)
    }

    Application.put_env(:macus, :state_dir, root)

    Application.put_env(:macus, IncusHost,
      owner_uid: File.stat!(root).uid,
      owner_key: @owner_key,
      ready: {__MODULE__, :ready?, [ready]}
    )

    on_exit(fn ->
      restore(:state_dir, previous.state_dir)
      restore(IncusHost, previous.host)
      restore(Macus.Incus, previous.incus)
      File.rm_rf!(root)
    end)

    {:ok, state} = Macus.Configuration.new(root)

    gateway = %Macus.Gateway{
      state: state,
      uid: File.stat!(root).uid,
      config: nil,
      certificate: nil,
      build: nil
    }

    %{root: root, sock: Path.join(root, "incus.sock"), ready: ready, gateway: gateway}
  end

  def ready?(agent), do: Agent.get(agent, & &1)

  defp restore(key, {:ok, value}), do: Application.put_env(:macus, key, value)
  defp restore(key, :error), do: Application.delete_env(:macus, key)

  describe "the pure library" do
    test "starts no process, listener or service, whatever PHX_SERVER and PORT say" do
      # No application callback: there is no tree to start.
      assert Application.spec(:opsmaru_incus, :mod) == []

      port = free_port()
      System.put_env("PHX_SERVER", "true")
      System.put_env("PORT", Integer.to_string(port))

      try do
        :ok = Application.stop(:opsmaru_incus)
        names = MapSet.new(Process.registered())
        ports = MapSet.new(Port.list())

        assert {:ok, [:opsmaru_incus]} = Application.ensure_all_started(:opsmaru_incus)

        assert MapSet.difference(MapSet.new(Process.registered()), names) |> MapSet.to_list() ==
                 []

        assert MapSet.difference(MapSet.new(Port.list()), ports) |> MapSet.to_list() == []
        assert {:error, :econnrefused} = :gen_tcp.connect(~c"127.0.0.1", port, [], 500)
      after
        System.delete_env("PHX_SERVER")
        System.delete_env("PORT")
        Application.ensure_all_started(:opsmaru_incus)
      end
    end

    test "Macus's tree adds only host-owned library components" do
      # Every :opsmaru_incus module Macus supervises is one the host owns
      # and configures: native exchange admission and the client workers.
      modules =
        for spec <- Macus.Proxy.child_specs() ++ Macus.Incus.child_specs(gateway()),
            %{start: {module, _, _}} = Supervisor.child_spec(spec, []),
            do: module

      library = Enum.filter(modules, &String.starts_with?(inspect(&1), "Opsmaru."))
      assert library == [Opsmaru.Incus.Gateway.Admission]
      # Opsmaru.Incus.ClientSupervisor is a bounded Task.Supervisor.
      assert Task.Supervisor in modules
    end
  end

  describe "client worker configuration" do
    test "workers start only with the serving gateway, bounded and optional", ctx do
      assert Macus.Incus.child_specs(nil) == []

      assert [%{id: Macus.Incus.Clients, start: {Task.Supervisor, :start_link, [opts]}}] =
               Macus.Incus.child_specs(ctx.gateway)

      assert opts[:name] == Macus.Incus.Clients
      assert opts[:max_children] == 16

      Application.put_env(:macus, Macus.Incus, client_workers: 2)
      assert [%{start: {_, _, [opts]}}] = Macus.Incus.child_specs(ctx.gateway)
      assert opts[:max_children] == 2

      Application.put_env(:macus, Macus.Incus, client_workers: false)
      assert Macus.Incus.child_specs(ctx.gateway) == []

      for invalid <- [0, 1025, "8", nil] do
        Application.put_env(:macus, Macus.Incus, client_workers: invalid)
        assert_raise ArgumentError, fn -> Macus.Incus.child_specs(ctx.gateway) end
      end
    end

    test "without the worker supervisor, client work is refused and nothing is sent", ctx do
      guest!(ctx)
      assert Macus.Incus.run(caller(), &get_instance/1) == {:error, :supervisor_unavailable}
      refute_receive {:incus, _, _, _, _}, 50
    end
  end

  describe "client work" do
    setup ctx do
      start_supervised!(hd(Macus.Incus.child_specs(ctx.gateway)))
      :ok
    end

    test "waits for trusted host readiness and sends nothing before it", ctx do
      guest!(ctx)
      Agent.update(ctx.ready, fn _ -> false end)

      assert {:error, %Incus.Error{kind: :host_not_ready}} =
               Macus.Incus.run(caller(), &get_instance/1)

      refute_receive {:incus, _, _, _, _}, 50

      Agent.update(ctx.ready, fn _ -> true end)
      assert {:ok, %{"name" => "c1"}} = Macus.Incus.run(caller(), &get_instance/1)
      assert_receive {:incus, "GET", "/1.0", _, _}
      assert_receive {:incus, "GET", "/1.0/instances/c1", _, _}
    end

    test "uses only the owner's incus.sock and refuses a foreign owner", ctx do
      guest!(ctx)

      assert {:ok, address} =
               Macus.Incus.run(caller(), fn client -> {:ok, client.connection.address} end)

      assert address == ctx.sock
      flush()

      assert {:error, _} =
               Macus.Incus.run(%{caller() | owner_key: "other"}, &get_instance/1)

      refute_receive {:incus, _, _, _, _}, 50

      # An unsafe socket is not ready either.
      File.chmod!(ctx.sock, 0o666)

      assert {:error, %Incus.Error{kind: :host_not_ready}} =
               Macus.Incus.run(caller(), &get_instance/1)

      refute_receive {:incus, _, _, _, _}, 50
    end

    test "capacity is bounded with no queue and the deadline is local", ctx do
      Application.put_env(:macus, Macus.Incus, client_workers: 1)
      stop_supervised!(Macus.Incus.Clients)
      start_supervised!(hd(Macus.Incus.child_specs(ctx.gateway)))
      guest!(ctx)
      test = self()

      busy =
        Task.async(fn ->
          Macus.Incus.run(caller(), fn _client ->
            send(test, :busy)
            receive(do: (:release -> :released))
          end)
        end)

      assert_receive :busy
      assert Macus.Incus.run(caller(), &get_instance/1) == {:error, :capacity}
      [worker] = Task.Supervisor.children(Macus.Incus.Clients)
      send(worker, :release)
      assert Task.await(busy) == :released

      assert Macus.Incus.run(caller(), fn _ -> Process.sleep(1_000) end, timeout: 100) ==
               {:error, :timeout}

      assert Task.Supervisor.children(Macus.Incus.Clients) == []
    end

    test "restarting the workers keeps the Swift runtime and its markers, with no MCP or central service",
         ctx do
      runtime = runtime!(ctx)
      guest!(ctx, %{{"GET", "/1.0/instances/slow"} => {:sleep, 2_000, {:sync, instance("slow")}}})
      before = snapshot(ctx.root)

      # Neither the operation index nor the MCP endpoint is needed.
      refute Process.whereis(Macus.Dex.Index)
      assert {:ok, %{"name" => "c1"}} = Macus.Incus.run(caller(), &get_instance/1)

      # An in-flight call loses its worker: it is reported, not retried.
      test = self()

      in_flight =
        Task.async(fn ->
          Macus.Incus.run(caller(), fn client ->
            send(test, :started)
            Incus.call(client, "GetInstance", %{"name" => "slow"})
          end)
        end)

      assert_receive :started
      assert_receive {:incus, "GET", "/1.0/instances/slow", _, _}, 1_000
      flush()
      supervisor = Process.whereis(Macus.Incus.Clients)
      Process.exit(supervisor, :kill)
      assert Task.await(in_flight) == {:error, :worker_exited}

      restarted = wait_for(fn -> Process.whereis(Macus.Incus.Clients) end)
      assert restarted != supervisor

      # The restart did no recovery work of its own.
      refute_receive {:incus, _, _, _, _}, 2_200
      assert HTTPFixture.requests(runtime) == []
      assert snapshot(ctx.root) == before

      assert {:ok, %{"name" => "c1"}} = Macus.Incus.run(caller(), &get_instance/1)
      assert snapshot(ctx.root) == before
      assert HTTPFixture.requests(runtime) == []
    end
  end

  defp get_instance(client) do
    case Incus.call(client, "GetInstance", %{"name" => "c1"}) do
      {:ok, %Incus.Response{metadata: %Incus.Model{type: "Instance", data: data}}} -> {:ok, data}
      other -> other
    end
  end

  defp caller do
    %TamaMCP.Context{
      request_id: 1,
      principal: "owner",
      owner_key: @owner_key,
      claims: %{},
      scopes: ["incus.read"]
    }
  end

  defp gateway do
    {:ok, state} = Macus.Configuration.new("/private/tmp")
    %Macus.Gateway{state: state, uid: 0, config: nil, certificate: nil, build: nil}
  end

  defp guest!(ctx, routes \\ %{}) do
    IncusBackend.start!(ctx.sock, self(),
      extensions: ["instances"],
      script: fn request ->
        Map.get(routes, {request.method, request.path}) || default(request)
      end
    )
  end

  defp default(%{method: "GET", path: "/1.0/instances/" <> name}),
    do: {:sync, instance(name)}

  defp default(_request), do: nil

  defp instance(name),
    do: %{"name" => name, "status" => "Running", "status_code" => 103, "type" => "container"}

  # A runtime.sock that records any request; Macus must send none.
  defp runtime!(ctx) do
    start_supervised!(
      {HTTPFixture,
       transport: :gen_tcp,
       path: Path.join(ctx.root, "runtime.sock"),
       handler: fn _ -> %{status: 500, body: %{}} end},
      id: :runtime
    )
  end

  # Every regular file in the state directory with its identity and content.
  defp snapshot(root) do
    for name <- File.ls!(root) |> Enum.sort(),
        %File.Stat{type: :regular} = stat <- [File.stat!(Path.join(root, name))],
        into: %{} do
      content = File.read!(Path.join(root, name))
      {name, {stat.inode, stat.size, stat.mtime, :crypto.hash(:sha256, content)}}
    end
  end

  defp flush do
    receive do
      {:incus, _, _, _, _} -> flush()
      {:incus_request_body, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp wait_for(fun, tries \\ 100) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(10)
        wait_for(fun, tries - 1)

      value ->
        value
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
