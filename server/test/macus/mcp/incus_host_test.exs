defmodule Macus.MCP.IncusHostTest do
  # The host reads the application environment, so run serially.
  use ExUnit.Case, async: false

  alias Macus.MCP.IncusHost
  alias Macus.TestSupport.HTTPFixture
  alias Opsmaru.Incus.Operations.Composite

  @owner_key "owner-key-1"
  @server %{
    "api_version" => "1.0",
    "api_extensions" => [],
    "api_status" => "stable",
    "auth" => "trusted",
    "environment" => %{"server" => "incus", "server_version" => "6.0.0"}
  }

  setup do
    root = Path.join("/private/tmp", "mc-host-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    uid = File.stat!(root).uid

    previous =
      {Application.fetch_env(:macus, :state_dir), Application.fetch_env(:macus, IncusHost)}

    {:ok, ready} = Agent.start_link(fn -> true end)

    Application.put_env(:macus, :state_dir, root)

    Application.put_env(:macus, IncusHost,
      owner_uid: uid,
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
         handler: fn _ -> %{status: 200, body: sync(@server)} end}
      )

    %{root: root, uid: uid, ready: ready, fixture: fixture}
  end

  def ready?(agent), do: Agent.get(agent, & &1)

  describe "binding to the local incus.sock" do
    test "a verified owner reaches the configured socket", ctx do
      assert {:ok, result} = run("incus_server_get", %{}, caller())
      assert is_map(result)
      assert [%{method: "GET", target: "/1.0"} | _] = HTTPFixture.requests(ctx.fixture)
    end

    test "a caller with another owner key gets no backend", ctx do
      assert {:error, %{"kind" => "host_binding_failed"}} =
               run("incus_server_get", %{}, caller(owner_key: "someone-else"))

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "a caller that is not a verified context gets no backend", ctx do
      forged = %{principal: "agent", owner_key: @owner_key, scopes: ["incus.read"]}

      for caller <- [forged, nil, caller(principal: nil)] do
        assert {:error, %{"kind" => "host_binding_failed"}} =
                 run("incus_server_get", %{}, caller)
      end

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "input cannot name an owner, socket or URL", ctx do
      forged = [
        %{"owner" => "someone-else"},
        %{"socket" => "/var/run/other.sock"},
        %{"url" => "https://incus.example.invalid:8443"},
        %{"server" => "https://incus.example.invalid:8443"},
        %{"project" => "default", "target" => "other-member"}
      ]

      for input <- forged do
        assert {:error, %{"kind" => "invalid_input"}} =
                 run("incus_instance_list", input, caller())
      end

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "missing or invalid host configuration denies every call", ctx do
      env = Application.get_env(:macus, IncusHost)

      for broken <- [
            Keyword.delete(env, :ready),
            Keyword.delete(env, :owner_key),
            Keyword.put(env, :owner_uid, -1),
            Keyword.put(env, :image_remotes, %{
              "images" => %{"server" => "http://images.invalid", "protocol" => "simplestreams"}
            })
          ] do
        Application.put_env(:macus, IncusHost, broken)

        assert {:error, %{"kind" => "host_binding_failed"}} =
                 run("incus_server_get", %{}, caller())
      end

      Application.put_env(:macus, IncusHost, env)
      Application.delete_env(:macus, :state_dir)
      assert {:error, %{"kind" => "host_binding_failed"}} = run("incus_server_get", %{}, caller())
      assert HTTPFixture.requests(ctx.fixture) == []
    end
  end

  describe "readiness gates dispatch" do
    test "nothing is sent while the host is not ready", ctx do
      Agent.update(ctx.ready, fn _ -> false end)
      assert {:error, %{"kind" => "host_not_ready"}} = run("incus_server_get", %{}, caller())
      assert HTTPFixture.requests(ctx.fixture) == []

      Agent.update(ctx.ready, fn _ -> true end)
      assert {:ok, _} = run("incus_server_get", %{}, caller())
      assert HTTPFixture.requests(ctx.fixture) != []
    end

    test "a readiness check that raises is not ready", ctx do
      env = Application.get_env(:macus, IncusHost)
      Application.put_env(:macus, IncusHost, Keyword.put(env, :ready, {Kernel, :exit, [:boom]}))

      assert {:error, %{"kind" => "host_not_ready"}} = run("incus_server_get", %{}, caller())
      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "a socket that is not owner-private is not ready", ctx do
      socket = Path.join(ctx.root, "incus.sock")
      File.chmod!(socket, 0o666)
      assert {:error, %{"kind" => "host_not_ready"}} = run("incus_server_get", %{}, caller())

      File.chmod!(socket, 0o600)
      File.chmod!(ctx.root, 0o755)
      assert {:error, %{"kind" => "host_not_ready"}} = run("incus_server_get", %{}, caller())

      File.chmod!(ctx.root, 0o700)
      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "a missing socket is not ready", ctx do
      stop_supervised!(HTTPFixture)
      refute File.exists?(Path.join(ctx.root, "incus.sock"))
      assert {:error, %{"kind" => "host_not_ready"}} = run("incus_server_get", %{}, caller())
    end
  end

  describe "authorization" do
    test "scopes passed by the executor must also be the caller's own", ctx do
      assert {:error, %{"kind" => "unauthorized"}} =
               run("incus_server_get", %{}, caller(scopes: []), ["incus.read"])

      assert HTTPFixture.requests(ctx.fixture) == []
    end

    test "a configured project list limits the projects input may name", ctx do
      env = Application.get_env(:macus, IncusHost)
      Application.put_env(:macus, IncusHost, Keyword.put(env, :projects, ["default"]))

      assert {:error, %{"kind" => "unauthorized"}} =
               run("incus_instance_list", %{"project" => "other"}, caller())

      assert HTTPFixture.requests(ctx.fixture) == []
      assert :ok = IncusHost.authorize(caller(), "incus_instance_list", %{"project" => "default"})
      assert :ok = IncusHost.authorize(caller(), "incus_instance_list", %{})
    end

    test "unknown operations are not authorized" do
      assert {:error, :unknown_operation} = IncusHost.authorize(caller(), "incus_shell", %{})
      assert {:error, :unknown_operation} = IncusHost.binding(caller(), "incus_shell")
    end
  end

  describe "image remotes and restricted input" do
    @create %{"name" => "c1", "image" => %{"alias" => "debian/12", "remote" => "images"}}

    test "image remotes are denied unless configured", ctx do
      assert {:error, %{"kind" => "image_remote_unavailable"}} =
               run("incus_instance_create", @create, caller(scopes: ["incus.write"]))

      assert HTTPFixture.requests(ctx.fixture) == []
      assert {:error, :not_approved} = IncusHost.image_remote(caller(), "images")

      remote = %{"server" => "https://images.example.invalid", "protocol" => "simplestreams"}
      env = Application.get_env(:macus, IncusHost)

      Application.put_env(
        :macus,
        IncusHost,
        Keyword.put(env, :image_remotes, %{"images" => remote})
      )

      assert {:ok, ^remote} = IncusHost.image_remote(caller(), "images")
      assert {:error, :not_approved} = IncusHost.image_remote(caller(), "other")
      assert {:error, :unauthenticated} = IncusHost.image_remote(caller(owner_key: "x"), "images")
    end

    test "restricted input is denied unless every item is configured", ctx do
      input =
        @create
        |> Map.update!("image", &Map.delete(&1, "remote"))
        |> Map.put("config", %{"security.privileged" => "true"})

      assert {:error, %{"kind" => "restricted_input"}} =
               run("incus_instance_create", input, caller(scopes: ["incus.write"]))

      assert HTTPFixture.requests(ctx.fixture) == []

      items = [{:config, "security.privileged"}, {:device, "host-share"}]
      refute IncusHost.allow_restricted?(caller(), "incus_instance_create", items)

      env = Application.get_env(:macus, IncusHost)
      Application.put_env(:macus, IncusHost, Keyword.put(env, :restricted, items))

      assert IncusHost.allow_restricted?(caller(), "incus_instance_create", items)
      assert IncusHost.allow_restricted?(caller(), "incus_instance_create", tl(items))

      refute IncusHost.allow_restricted?(
               caller(),
               "incus_instance_create",
               [{:config, "raw.lxc"} | items]
             )

      refute IncusHost.allow_restricted?(caller(owner_key: "x"), "incus_instance_create", items)
    end
  end

  defp run(operation, input, caller, scopes \\ nil) do
    scopes =
      scopes || if(match?(%TamaMCP.Context{}, caller), do: caller.scopes, else: ["incus.read"])

    Composite.run(operation, input, host: IncusHost, caller: caller, scopes: scopes)
  end

  defp caller(overrides \\ []) do
    struct!(
      %TamaMCP.Context{
        request_id: 1,
        principal: "owner",
        owner_key: @owner_key,
        claims: %{},
        scopes: ["incus.read"]
      },
      overrides
    )
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

  defp restore(key, {:ok, value}), do: Application.put_env(:macus, key, value)
  defp restore(key, :error), do: Application.delete_env(:macus, key)
end
