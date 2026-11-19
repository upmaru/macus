defmodule Macus.Proxy.ImageAdmissionTest do
  # Macus host policy for image-copy server peers (`admit_image_secret/2`)
  # against a fixture guest incus.sock listing its pending operations.
  use ExUnit.Case, async: true

  alias Macus.Proxy.Host
  alias Macus.TestSupport.{DexFixtures, HTTPFixture}
  alias Opsmaru.Incus.Connection
  alias Opsmaru.Incus.Gateway.Request

  @fp String.duplicate("c0ffee", 10) <> "abcd"
  @now ~U[2026-11-19 12:00:00Z]

  setup do
    root = DexFixtures.private_root!()
    on_exit(fn -> File.rm_rf!(root) end)
    test = self()

    operations = %{
      "running" => [
        token("pull-token", "pull-secret", @fp),
        %{"id" => "other", "class" => "task", "metadata" => %{"secret" => "task-secret"}}
      ],
      "cancelled" => [token("used-token", "used-secret", @fp)],
      "success" => [
        %{
          "id" => "0b1c2d3e-0000-4000-8000-000000000001",
          "class" => "task",
          "metadata" => %{"secret" => "wait-secret"}
        }
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

    config = %{connection: connection, clock: fn -> @now end, image_grant_ttl: 60_000}
    %{config: config, fixture: fixture}
  end

  test "info, export and upload are admitted only for a matching pending image token",
       %{config: config} do
    for route <- [:info, :export, :upload] do
      assert {:ok, grant} = Host.admit_image_secret(request(route, "pull-secret"), config)
      assert grant == %{image: route, expires: DateTime.add(@now, 60_000, :millisecond)}
      assert_received {:backend, "GET", "/1.0/operations?recursion=1&project=image-project"}
    end

    # A short fingerprint prefix matches as natively, and a token whose first
    # use already cancelled it still admits the following export.
    assert {:ok, _} = Host.admit_image_secret(request(:info, "pull-secret", "c0ffee"), config)
    assert {:ok, _} = Host.admit_image_secret(request(:export, "used-secret"), config)
  end

  test "a wrong secret, fingerprint, class or project selection is refused", %{config: config} do
    for request <- [
          request(:info, "wrong-secret"),
          request(:export, "pull-secret!"),
          request(:upload, "pull"),
          request(:info, "pull-secret", "deadbeef"),
          # A secret on another kind of operation is not an image token.
          request(:info, "task-secret"),
          # A wait secret only admits its own wait.
          request(:export, "wait-secret"),
          request(:info, "pull-secret") |> Map.put(:project, "other-project")
        ] do
      assert {:error, :forbidden} = Host.admit_image_secret(request, config)
    end
  end

  test "a wait is admitted only for the named operation and its own secret", %{config: config} do
    id = "0b1c2d3e-0000-4000-8000-000000000001"

    assert {:ok, %{image: :wait}} =
             Host.admit_image_secret(request(:wait, "wait-secret", nil, id), config)

    assert_received {:backend, "GET", "/1.0/operations/" <> ^id <> "?project=image-project"}

    for {secret, operation} <- [
          {"wrong-secret", id},
          {"pull-secret", "pull-token"},
          {"wait-secret", "0b1c2d3e-0000-4000-8000-000000000002"}
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
          request(:wait, "wait-secret", nil, "../instances"),
          request(:wait, "wait-secret", nil, nil),
          request(:info, "pull-secret") |> Map.put(:target, "member"),
          request(:info, "pull-secret") |> Map.put(:image, %{route: :delete, secret: "s"}),
          request(:info, "pull-secret") |> Map.delete(:image)
        ] do
      assert {:error, :forbidden} = Host.admit_image_secret(request, config)
    end

    refute_received {:backend, _, _}

    assert {:error, :forbidden} =
             Host.admit_image_secret(
               request(:info, "pull-secret") |> Map.put(:project, "failing"),
               config
             )

    assert {:error, :forbidden} =
             Host.admit_image_secret(
               request(:info, "pull-secret"),
               Map.delete(config, :connection)
             )
  end

  test "an image grant is valid until its expiry and holds no secret", %{config: config} do
    {:ok, grant} = Host.admit_image_secret(request(:info, "pull-secret"), config)
    refute inspect(grant) =~ "pull-secret"
    assert Host.valid?(request(:info, "pull-secret"), grant, config)

    later = %{config | clock: fn -> DateTime.add(@now, 60, :second) end}
    refute Host.valid?(request(:info, "pull-secret"), grant, later)
  end

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
