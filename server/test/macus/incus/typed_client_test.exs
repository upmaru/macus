defmodule Macus.Incus.TypedClientTest do
  # Task 2.3: Macus binds the locked :opsmaru_incus typed codecs, version
  # checks and native errors over its own incus.sock binding, and implements
  # none of them. A scripted guest answers each case. Changes global
  # configuration.
  use ExUnit.Case, async: false

  alias Macus.Incus.Coverage
  alias Macus.MCP.IncusHost
  alias Macus.TestSupport.IncusBackend
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Error, Model, Response}

  @owner_key "macus-owner:typed"
  @server Path.expand("../../..", __DIR__)
  @op "00000000-0000-4000-8000-0000000000aa"

  setup do
    root = Path.join("/private/tmp", "mc-tc-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)

    previous =
      {Application.fetch_env(:macus, :state_dir), Application.fetch_env(:macus, IncusHost)}

    Application.put_env(:macus, :state_dir, root)

    Application.put_env(:macus, IncusHost,
      owner_uid: File.stat!(root).uid,
      owner_key: @owner_key,
      ready: {__MODULE__, :ready?, []}
    )

    on_exit(fn ->
      restore(:state_dir, elem(previous, 0))
      restore(IncusHost, elem(previous, 1))
      File.rm_rf!(root)
    end)

    %{sock: Path.join(root, "incus.sock")}
  end

  def ready?, do: true

  defp restore(key, {:ok, value}), do: Application.put_env(:macus, key, value)
  defp restore(key, :error), do: Application.delete_env(:macus, key)

  describe "the pinned dependency" do
    test "is the locked revision with one reference across library and Macus fixtures" do
      locked = Macus.Build.identity().opsmaru_incus.version
      assert to_string(Application.spec(:opsmaru_incus, :vsn)) == locked
      assert Macus.Build.check(nil, locked) == {:error, :missing_revision}

      reference = Coverage.reference()
      assert reference["tag"] == "v7.0.1"
      assert Coverage.coverage()["reference_revision"] == reference["revision"]
      assert Coverage.inventory()["reference"] == reference
      assert Coverage.transfer()["reference_revision"] == reference["revision"]

      wire =
        Path.join(@server, "test/fixtures/incus/wire.json") |> File.read!() |> Jason.decode!()

      assert wire["reference_revision"] == reference["revision"]

      # The Go reference driver Macus retains builds against the same tag.
      assert File.read!(Path.join(@server, "test/reference/go.mod")) =~
               "github.com/lxc/incus/v7 #{reference["tag"]}"
    end

    test "Macus implements no codec, model or inventory of its own" do
      sources = Path.wildcard(Path.join(@server, "lib/**/*.ex"))

      for file <- sources do
        content = File.read!(file)
        relative = Path.relative_to(file, @server)
        # No pinned model schemas, method tables or constants of its own.
        # Evidence is the single exception: it must name those records to
        # verify the linked evidence's provenance (10.3), through
        # Macus.Incus.Coverage.dir/0, and it never implements codec data.
        if relative != "lib/macus/incus/evidence.ex",
          do:
            refute(
              content =~ ~r/models\.json|methods\.json|constants\.json/,
              "#{relative} reads library codec data"
            )

        # Reference records are read only through Coverage, from the
        # dependency; the two modules that document the records' directory
        # may name it.
        if relative not in ~w(lib/macus/incus/coverage.ex lib/macus/incus/evidence.ex),
          do: refute(content =~ "priv/incus", "#{relative} reads Incus records itself")

        refute content =~ ~r/defmodule Macus\.Incus\.(Model|Inventory|Codec|Response|Error)\b/,
               "#{relative} duplicates a library module"
      end

      refute File.exists?(Path.join(@server, "priv/incus"))
    end
  end

  describe "typed responses through Macus's binding" do
    test "populated, absent and null fields decode losslessly", ctx do
      populated = %{
        "name" => "full",
        "status" => "Running",
        "status_code" => 103,
        "config" => %{"limits.cpu" => "2"},
        "expanded_devices" => %{"root" => %{"type" => "disk", "path" => "/"}},
        "future_field" => %{"kept" => true}
      }

      sparse = %{"name" => "sparse"}

      nulls = %{
        "name" => "nulls",
        "config" => nil,
        "devices" => nil,
        "profiles" => nil,
        "description" => nil
      }

      guest!(ctx, %{
        {"GET", "/1.0/instances/full"} => {:sync, 200, populated, %{"etag" => ~s("e1")}},
        {"GET", "/1.0/instances/sparse"} => {:sync, sparse},
        {"GET", "/1.0/instances/nulls"} => {:sync, nulls}
      })

      client = client!()

      assert {:ok,
              %Response{etag: ~s("e1"), metadata: %Model{type: "Instance", data: ^populated}}} =
               get(client, "full")

      # Absent optional fields stay absent; nothing is defaulted in.
      assert {:ok, %Response{etag: "", metadata: %Model{type: "Instance", data: ^sparse}}} =
               get(client, "sparse")

      # Present nulls are kept, not dropped or replaced.
      assert {:ok, %Response{metadata: %Model{type: "Instance", data: ^nulls}}} =
               get(client, "nulls")
    end

    test "wrongly typed or malformed data fails without a retry", ctx do
      guest!(ctx, %{
        {"GET", "/1.0/instances/corrupt"} => {:sync, %{"name" => 5, "status_code" => "x"}},
        {"GET", "/1.0/instances/list"} => {:sync, ["not", "an", "instance"]},
        {"GET", "/1.0/instances/garbage"} =>
          {:binary, 200, %{"content-type" => "application/json"}, "{not json"}
      })

      client = client!()
      flush()

      assert {:error, %Error{kind: :invalid_model}} = get(client, "corrupt")
      assert {:error, %Error{kind: :invalid_model}} = get(client, "list")
      assert {:error, %Error{kind: :invalid_envelope}} = get(client, "garbage")

      for name <- ~w(corrupt list garbage) do
        path = "/1.0/instances/" <> name
        assert_receive {:incus, "GET", ^path, _, _}
        refute_receive {:incus, "GET", ^path, _, _}, 20
      end
    end

    test "native errors keep their status, code and message", ctx do
      guest!(ctx, %{
        {"GET", "/1.0/instances/missing"} => {:error, 404, "Instance not found"},
        {"GET", "/1.0/instances/denied"} => {:error, 403, "not authorized"},
        {"GET", "/1.0/instances/broken"} => {:error, 500, "boom"}
      })

      client = client!()

      for {name, status, message} <- [
            {"missing", 404, "Instance not found"},
            {"denied", 403, "not authorized"},
            {"broken", 500, "boom"}
          ] do
        assert {:error, %Error{kind: :native} = error} = get(client, name)
        assert {error.http_status, error.error_code, error.message} == {status, status, message}
        # Rendering never leaks the native message.
        refute inspect(error) =~ message
      end
    end

    test "mutations send the native body and ETag once; an unexpected reply is uncertain",
         ctx do
      body = %{"description" => "d", "config" => nil, "profiles" => ["default"]}

      guest!(ctx, %{
        {"PUT", "/1.0/instances/c1"} => {:async, operation()},
        {"PUT", "/1.0/instances/c2"} => {:sync, %{}}
      })

      client = client!()
      flush()

      assert {:ok, %Response{type: "async", operation: "/1.0/operations/" <> @op}} =
               Incus.call(client, "UpdateInstance", %{"name" => "c1"},
                 body: body,
                 etag: ~s("e1")
               )

      assert_receive {:incus, "PUT", "/1.0/instances/c1", _, %{"if-match" => ~s("e1")}}
      assert_receive {:incus_request_body, "PUT", "/1.0/instances/c1", sent}
      assert Jason.decode!(sent) == body

      # A synchronous reply to a background mutation may still have been
      # accepted: it is uncertain and is not sent again.
      assert {:error, %Error{kind: :uncertain}} =
               Incus.call(client, "UpdateInstance", %{"name" => "c2"}, body: body)

      assert_receive {:incus, "PUT", "/1.0/instances/c2", _, _}
      refute_receive {:incus, "PUT", "/1.0/instances/c2", _, _}, 50
    end
  end

  describe "version and extension checks" do
    test "an unsupported API version is refused after discovery only", ctx do
      guest!(ctx, %{{"GET", "/1.0"} => {:sync, discovery("2.0")}})

      assert {:error, %Error{kind: :unsupported_version}} = IncusHost.client(caller())
      assert_receive {:incus, "GET", "/1.0", _, _}
      refute_receive {:incus, _, _, _, _}, 50
    end

    test "a discovery record without extensions is not a server", ctx do
      guest!(ctx, %{{"GET", "/1.0"} => {:sync, Map.delete(discovery("1.0"), "api_extensions")}})
      assert {:error, %Error{kind: :invalid_server}} = IncusHost.client(caller())
    end

    test "a method needing an absent extension fails before its request", ctx do
      guest!(ctx)
      client = client!()
      flush()

      assert {:error, %Error{kind: :unsupported_extension, extension: "warnings"}} =
               Incus.call(client, "GetWarnings", %{})

      refute_receive {:incus, _, _, _, _}, 50
    end
  end

  defp get(client, name), do: Incus.call(client, "GetInstance", %{"name" => name})

  defp client! do
    {:ok, client} = IncusHost.client(caller())
    client
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

  defp guest!(ctx, routes \\ %{}) do
    IncusBackend.start!(ctx.sock, self(),
      extensions: ["instances"],
      script: fn request -> Map.get(routes, {request.method, request.path}) end
    )
  end

  defp discovery(version) do
    %{
      "api_extensions" => ["instances"],
      "api_status" => "stable",
      "api_version" => version,
      "auth" => "trusted",
      "public" => false,
      "auth_methods" => ["tls"],
      "config" => %{},
      "environment" => %{"server_name" => "incus-guest", "server_version" => "7.0"}
    }
  end

  defp operation do
    %{
      "id" => @op,
      "class" => "task",
      "status" => "Running",
      "status_code" => 103,
      "resources" => %{"instances" => ["/1.0/instances/c1"]},
      "metadata" => nil,
      "may_cancel" => false,
      "err" => "",
      "created_at" => "2026-11-19T00:00:00Z",
      "updated_at" => "2026-11-19T00:00:00Z",
      "location" => "none"
    }
  end

  defp flush do
    receive do
      {:incus, _, _, _, _} -> flush()
      {:incus_request_body, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end
