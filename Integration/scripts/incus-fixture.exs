# The guest's incus.sock for the cross-component fixture (task 10.2), run outside ExUnit:
#
#   cd server && MIX_ENV=test mise exec -- mix run --no-start \
#     ../Integration/scripts/incus-fixture.exs SOCKET LOG
#
# Serves Macus.TestSupport.IncusBackend at SOCKET and appends one JSON line per backend
# request, WebSocket and channel to LOG. It adds the routes the guest bridge's health check
# and the standard `incus exec` client need. "ready" is printed once SOCKET accepts; the
# fixture exits when its standard input closes. It is never a guest and never acceptance.

[socket, log] = System.argv()
{:ok, _} = Application.ensure_all_started(:cowboy)
{:ok, _} = Application.ensure_all_started(:jason)
alias Macus.TestSupport.IncusBackend

exec = IncusBackend.exec_ok()

operation = fn status, code, metadata ->
  %{
    "id" => exec,
    "class" => "websocket",
    "description" => "Executing command",
    "created_at" => "2026-11-21T00:00:00Z",
    "updated_at" => "2026-11-21T00:00:00Z",
    "status" => status,
    "status_code" => code,
    "resources" => %{"instances" => ["/1.0/instances/c1"]},
    "metadata" => metadata,
    "may_cancel" => false,
    "err" => "",
    "location" => "none"
  }
end

instance = fn name ->
  %{
    "name" => name,
    "description" => "",
    "status" => "Running",
    "status_code" => 103,
    "type" => "container",
    "project" => "default",
    "location" => "none",
    "architecture" => "aarch64",
    "created_at" => "2026-11-21T00:00:00Z",
    "last_used_at" => "2026-11-21T00:00:00Z",
    "ephemeral" => false,
    "stateful" => false,
    "profiles" => ["default"],
    "config" => %{},
    "devices" => %{},
    "expanded_config" => %{},
    "expanded_devices" => %{}
  }
end

script = fn
  %{method: "GET", path: "/internal/ready"} ->
    {:sync, %{}}

  %{method: "GET", path: "/1.0/instances", qs: qs} when qs != "" ->
    if String.contains?(qs, "recursion=") and not String.contains?(qs, "recursion=0") do
      {:sync, Enum.map(["c1", "c2"], instance)}
    end

  %{method: "GET", path: "/1.0/instances/" <> name} when name in ["c1", "c2"] ->
    {:sync, 200, instance.(name), %{"etag" => ~s("etag-#{name}")}}

  %{method: "GET", path: "/1.0/instances/" <> rest} when rest in ["c1/state", "c2/state"] ->
    {:sync, %{"status" => "Running", "status_code" => 103, "network" => %{}}}

  %{method: "GET", path: "/1.0/instances/" <> rest}
  when rest in ["c1/snapshots", "c2/snapshots"] ->
    {:sync, []}

  %{method: "POST", path: "/1.0/instances/c1/exec"} ->
    {:async,
     operation.("Running", 103, %{
       "fds" => %{"0" => "s0", "1" => "s1", "2" => "s2", "control" => "sc"}
     })}

  %{method: "GET", path: "/1.0/operations/" <> rest} when rest in [exec, exec <> "/wait"] ->
    {:sync, operation.("Success", 200, %{"return" => 0})}

  _ ->
    nil
end

file = File.open!(log, [:append, :utf8])

observer =
  spawn(fn ->
    loop = fn loop ->
      receive do
        message ->
          entry =
            case message do
              {:incus_request_body, _method, _path, _body} ->
                nil

              {:incus, method, path, qs, headers} ->
                %{kind: "request", method: method, path: path, qs: qs, headers: Map.keys(headers)}

              {:incus_ws, _pid, path} ->
                %{kind: "websocket", path: path}

              {:incus_channel, operation, secret} ->
                %{kind: "channel", operation: operation, secret: secret}

              other ->
                %{kind: "event", event: inspect(elem(other, 0))}
            end

          if entry, do: IO.write(file, Jason.encode!(entry) <> "\n")
          loop.(loop)
      end
    end

    loop.(loop)
  end)

# Extensions the standard client checks before list, exec and monitor.
extensions = [
  "certificate_update",
  "instances",
  "projects",
  "api_filtering",
  "instance_all_projects",
  "container_exec_signal_handling",
  "container_exec_recording",
  "event_lifecycle",
  "operation_wait"
]

IncusBackend.start!(socket, observer, script: script, extensions: extensions, on_exit: false)
IO.puts("ready")
IO.read(:stdio, :eof)
