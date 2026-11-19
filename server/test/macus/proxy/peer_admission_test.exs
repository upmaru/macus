defmodule Macus.Proxy.PeerAdmissionTest do
  # Macus host policy for server peers without a gateway certificate:
  # migration channels (`admit_operation_secret/2`) and image copies
  # (`admit_image_secret/2`), against a fixture guest incus.sock listing its
  # pending operations.
  use ExUnit.Case, async: true

  alias Macus.Proxy.Host
  alias Macus.TestSupport.{DexFixtures, HTTPFixture}
  alias Opsmaru.Incus.Connection
  alias Opsmaru.Incus.Gateway.Request

  @fp String.duplicate("c0ffee", 10) <> "abcd"
  @now ~U[2026-11-19 12:00:00Z]
  @migration "a0000000-0000-4000-8000-000000000001"
  @default_migration "a0000000-0000-4000-8000-000000000002"
  @exec "a0000000-0000-4000-8000-000000000003"
  @extra "a0000000-0000-4000-8000-000000000004"
  @finished "a0000000-0000-4000-8000-000000000005"

  setup do
    root = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    test = self()

    operations = %{
      "running" => [
        token("pull-token", secret("pull-secret"), @fp),
        %{"id" => "other", "class" => "task", "metadata" => %{"secret" => secret("task-secret")}}
      ],
      "cancelled" => [token("used-token", secret("used-secret"), @fp)],
      "success" => [
        %{
          "id" => "0b1c2d3e-0000-4000-8000-000000000001",
          "class" => "task",
          "metadata" => %{"secret" => secret("wait-secret")}
        }
      ],
      "migrations" => [
        migration(
          @migration,
          %{"control" => secret("control-secret"), "fs" => secret("fs-secret")},
          "image-project"
        ),
        migration(
          @default_migration,
          %{"control" => secret("c"), "criu" => secret("criu-secret")},
          nil
        ),
        migration(
          @exec,
          %{"fds" => %{"0" => secret("stdin-secret"), "control" => secret("exec-control")}},
          nil
        ),
        migration(@extra, %{"control" => secret("x-control"), "other" => secret("x-other")}, nil),
        Map.put(
          migration(@finished, %{"control" => secret("done-secret")}, nil),
          "status",
          "Success"
        )
      ]
    }

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "incus.sock"),
         handler: fn request ->
           send(test, {:backend, request.method, request.target})
           respond(URI.parse(request.target), operations)
         end}
      )

    connection =
      Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: {:macus, "macus-owner:501"})

    config = %{connection: connection, clock: fn -> @now end, peer_grant_ttl: 60_000}
    %{config: config, fixture: fixture}
  end

  test "info, export and upload are admitted only for a matching pending image token",
       %{config: config} do
    for route <- [:info, :export, :upload] do
      assert {:ok, grant} = Host.admit_image_secret(request(route, secret("pull-secret")), config)
      assert grant == %{peer: :image, expires: DateTime.add(@now, 60_000, :millisecond)}
      assert_received {:backend, "GET", "/1.0/operations?recursion=1&project=image-project"}
    end

    # A short fingerprint prefix matches as natively, and a token whose first
    # use already cancelled it still admits the following export.
    assert {:ok, _} =
             Host.admit_image_secret(request(:info, secret("pull-secret"), "c0ffee"), config)

    assert {:ok, _} = Host.admit_image_secret(request(:export, secret("used-secret")), config)
  end

  test "a wrong secret, fingerprint, class or project selection is refused", %{config: config} do
    for request <- [
          request(:info, secret("wrong-secret")),
          request(:export, secret("pull-secret!")),
          request(:upload, secret("pull")),
          request(:info, secret("pull-secret"), "deadbeef"),
          # A secret on another kind of operation is not an image token.
          request(:info, secret("task-secret")),
          # A wait secret only admits its own wait.
          request(:export, secret("wait-secret")),
          request(:info, secret("pull-secret")) |> Map.put(:project, "other-project")
        ] do
      assert {:error, :forbidden} = Host.admit_image_secret(request, config)
    end
  end

  test "a wait is admitted only for the named operation and its own secret", %{config: config} do
    id = "0b1c2d3e-0000-4000-8000-000000000001"

    assert {:ok, %{peer: :image}} =
             Host.admit_image_secret(request(:wait, secret("wait-secret"), nil, id), config)

    assert_received {:backend, "GET", "/1.0/operations/" <> ^id <> "?project=image-project"}

    for {secret, operation} <- [
          {secret("wrong-secret"), id},
          {secret("pull-secret"), "pull-token"},
          {secret("wait-secret"), "0b1c2d3e-0000-4000-8000-000000000002"}
        ] do
      assert {:error, :forbidden} =
               Host.admit_image_secret(request(:wait, secret, nil, operation), config)
    end
  end

  test "malformed requests, a cluster target and backend failures are refused before or at the backend",
       %{config: config} do
    for request <- [
          request(:info, ""),
          request(:info, nil),
          request(:info, "pull-secret"),
          request(:wait, secret("wait-secret"), nil, "0b1c2d3e"),
          request(:wait, secret("wait-secret"), nil, "../instances"),
          request(:wait, secret("wait-secret"), nil, nil),
          request(:info, secret("pull-secret")) |> Map.put(:target, "member"),
          request(:info, secret("pull-secret"))
          |> Map.put(:image, %{route: :delete, secret: "s"}),
          request(:info, secret("pull-secret")) |> Map.delete(:image)
        ] do
      assert {:error, :forbidden} = Host.admit_image_secret(request, config)
    end

    refute_received {:backend, _, _}

    assert {:error, :forbidden} =
             Host.admit_image_secret(
               request(:info, secret("pull-secret")) |> Map.put(:project, "failing"),
               config
             )

    assert {:error, :forbidden} =
             Host.admit_image_secret(
               request(:info, secret("pull-secret")),
               Map.delete(config, :connection)
             )
  end

  test "an image grant is valid until its expiry and holds no secret", %{config: config} do
    {:ok, grant} = Host.admit_image_secret(request(:info, secret("pull-secret")), config)
    refute inspect(grant) =~ secret("pull-secret")
    assert Host.valid?(request(:info, secret("pull-secret")), grant, config)

    later = %{config | clock: fn -> DateTime.add(@now, 60, :second) end}
    refute Host.valid?(request(:info, secret("pull-secret")), grant, later)
  end

  test "a migration channel is admitted only for a running migration and one of its secrets",
       %{config: config} do
    for secret <- [secret("control-secret"), secret("fs-secret")],
        project <- ["image-project", nil] do
      assert {:ok, grant} =
               Host.admit_operation_secret(websocket(@migration, secret, project), config)

      assert grant == %{peer: :migration, expires: DateTime.add(@now, 60_000, :millisecond)}
      refute inspect(grant) =~ secret
    end

    assert_received {:backend, "GET",
                     "/1.0/operations/" <> @migration <> "?project=image-project"}

    # The legacy criu channel name, in the default project.
    assert {:ok, _} =
             Host.admit_operation_secret(
               websocket(@default_migration, secret("criu-secret")),
               config
             )

    assert {:ok, _} =
             Host.admit_operation_secret(
               websocket(@default_migration, secret("c"), "default"),
               config
             )
  end

  test "exec, console, finished, mismatched and malformed migration requests are refused",
       %{config: config} do
    for request <- [
          websocket(@migration, secret("wrong-secret")),
          websocket(@migration, secret("control-secret"), "other-project"),
          websocket(@default_migration, secret("criu-secret"), "image-project"),
          # An exec or console operation nests its channel secrets under fds.
          websocket(@exec, secret("stdin-secret")),
          websocket(@exec, secret("exec-control")),
          # Metadata with anything besides migration channels is not a migration.
          websocket(@extra, secret("x-control")),
          websocket(@finished, secret("done-secret")),
          websocket("a0000000-0000-4000-8000-000000000009", secret("control-secret"))
        ] do
      assert {:error, :forbidden} = Host.admit_operation_secret(request, config)
    end

    flush_backend()

    for request <- [
          websocket("../instances", secret("control-secret")),
          websocket(nil, secret("control-secret")),
          websocket("abc", secret("control-secret")),
          websocket(@migration, "guess"),
          websocket(@migration, String.upcase(secret("control-secret"))),
          %{websocket(@migration, secret("control-secret")) | query: ""},
          %{websocket(@migration, secret("control-secret")) | query: "secret="},
          %{websocket(@migration, secret("control-secret")) | query: "secret=a&secret=b"},
          %{websocket(@migration, secret("control-secret")) | target: "member"}
        ] do
      assert {:error, :forbidden} = Host.admit_operation_secret(request, config)
    end

    refute_received {:backend, _, _}
  end

  test "a migration grant is valid until its expiry", %{config: config} do
    {:ok, grant} =
      Host.admit_operation_secret(websocket(@migration, secret("control-secret")), config)

    assert Host.valid?(websocket(@migration, secret("control-secret")), grant, config)
    later = %{config | clock: fn -> DateTime.add(@now, 60, :second) end}
    refute Host.valid?(websocket(@migration, secret("control-secret")), grant, later)

    refute Host.valid?(
             websocket(@migration, secret("control-secret")),
             %{peer: :other, expires: @now},
             config
           )
  end

  defp migration(id, metadata, project),
    do: %{
      "id" => id,
      "class" => "websocket",
      "status" => "Running",
      "resources" => %{
        "instances" => [
          "/1.0/instances/source" <> if(project, do: "?project=#{project}", else: "")
        ]
      },
      "metadata" => metadata
    }

  defp websocket(operation, secret, project \\ nil),
    do: %Request{
      protocol: :websocket,
      method: "GET",
      path: "/1.0/operations/#{operation}/websocket",
      query: URI.encode_query(%{"secret" => secret}),
      project: project,
      operation: operation,
      peer: %{address: {192, 0, 2, 10}, port: 40_000, certificate: nil}
    }

  defp flush_backend do
    receive do
      {:backend, _, _} -> flush_backend()
    after
      0 -> :ok
    end
  end

  # A secret in incusd's format: 32 random bytes in lowercase hex.
  defp secret(name), do: Base.encode16(:crypto.hash(:sha256, name), case: :lower)

  defp token(id, secret, fingerprint),
    do: %{
      "id" => id,
      "class" => "token",
      "resources" => %{"images" => ["/1.0/images/#{fingerprint}?project=image-project"]},
      "metadata" => %{"secret" => secret}
    }

  defp respond(%URI{path: "/1.0/operations", query: query}, operations) do
    case URI.decode_query(query || "")["project"] do
      "image-project" -> sync(operations)
      "failing" -> %{status: 500, body: %{type: "error", error: "failed", error_code: 500}}
      _ -> sync(%{})
    end
  end

  defp respond(%URI{path: "/1.0/operations/" <> id}, operations) do
    case operations |> Map.values() |> Enum.concat() |> Enum.find(&(&1["id"] == id)) do
      nil -> %{status: 404, body: %{type: "error", error: "not found", error_code: 404}}
      operation -> sync(operation)
    end
  end

  defp sync(metadata),
    do: %{
      status: 200,
      body: %{type: "sync", status: "Success", status_code: 200, metadata: metadata}
    }

  # opsmaru_incus releases before the image callback have no :image field on
  # the request struct; the host reads it as a map key.
  defp request(route, secret, fingerprint \\ @fp, operation \\ nil) do
    %Request{
      protocol: :http,
      method: if(route == :upload, do: "POST", else: "GET"),
      path: "/1.0/images",
      query: "",
      project: "image-project",
      operation: operation,
      peer: %{address: {192, 0, 2, 10}, port: 40_000, certificate: nil}
    }
    |> Map.put(:image, %{
      route: route,
      fingerprint: if(route == :wait, do: nil, else: fingerprint),
      secret: secret
    })
  end
end
