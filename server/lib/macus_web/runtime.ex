defmodule MacusWeb.Runtime do
  @moduledoc """
  The public runtime API at `/runtime`: allowlisted methods mapped to the
  private Swift routes beneath `/v1/runtime` (`Macus.Runtime.Client`), with
  no version in the public path.

  | Public | Private | Scope |
  | --- | --- | --- |
  | `GET /runtime/status` | `GET /v1/runtime/status` | `runtime.read` |
  | `GET /runtime/capabilities`, `health`, `config`, `progress` | same beneath `/v1/runtime` | `runtime.read` |
  | `POST /runtime/create` | `POST /v1/runtime/create` | `runtime.write` |
  | `POST /runtime/start`, `restart` | same | `runtime.write` |
  | `POST /runtime/stop` | `POST /v1/runtime/stop` | `runtime.write`; `runtime.delete` to force |
  | `PUT /runtime/config` | `PUT /v1/runtime/config` | `runtime.write` |
  | `DELETE /runtime` | `DELETE /v1/runtime` | `runtime.delete` |

  Every request needs a Macus bearer credential (`Macus.Auth.Bearer`) of
  the runtime's owner and the route's scope, checked before the body is
  read or any private request is made; it is registered with
  `Macus.Auth.Streams` for the request's duration, so revoking it ends a
  long start within the documented bound (the Swift runtime keeps whatever
  it was doing). An unknown path is 404 and a known path with another
  method 405, both before backend access.

  Bodies are read here, at most 1 MiB, with no global parser:

  - `create` and `PUT config` take a complete schema 1 configuration
    object; a missing, unknown or mistyped field is refused before dispatch
    and the original bytes are forwarded, so Swift applies its own
    validation (ranges, paths, the stopped-runtime precondition).
  - `start` takes an empty body or `{"remaining_seconds": N}`, forwarded
    unchanged; the request deadline covers that budget.
  - `stop` takes an empty body, `{"force": false}`, or `{"force": true,
    "confirm": "force-stop"}` (scope `runtime.delete`), forwarded as the
    private `{"force": ...}`.
  - `DELETE /runtime` takes `{"confirm": "delete-runtime"}`, forwarded as
    the private `{"confirm": true}`.

  Swift responses keep their status and JSON bytes (errors and 409
  conflicts included), except that a runtime status object is projected:
  the private `incus_socket` path is removed and `server_endpoint`,
  `incus_endpoint` (the gateway's URL and certificate fingerprint),
  `server_ready` and `runtime_ready` are added. When the Swift service
  cannot be reached, status answers 503 with `server_ready: true` and
  `runtime_ready: false`, so the gateway's own availability stays
  distinguishable from the runtime's. Transport failures never retry a
  request that may have been accepted; `outcome` says whether it was
  `not_dispatched`, `read_only` or `unknown`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Macus.Runtime.{Client, Error, Response}

  @body_limit 1_048_576
  @reads ~w(status capabilities health config progress)
  @read_timeout 15_000
  @mutation_timeout 3_600_000
  @stop_timeout 330_000
  @config_fields %{
    "schema_version" => :integer,
    "cpu_count" => :integer,
    "memory_mib" => :integer,
    "data_disk_gib" => :integer,
    "appliance_manifest_path" => :string,
    "nested_virtualization" => :boolean,
    "shares" => :shares,
    "readiness_timeout_seconds" => :integer,
    "shutdown_timeout_seconds" => :integer
  }
  @optional_config_fields %{"seed_path" => :nullable_string}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn = put_resp_content_type(conn, "application/json")

    with {:ok, route} <- route(conn.method, conn.path_info),
         {:ok, owner} <- authenticate(conn, route.scope) do
      try do
        handle(conn, route, owner)
      after
        Macus.Auth.Streams.unregister()
      end
    else
      {:error, status, code, message} -> error(conn, status, code, message, "not_dispatched")
      {:error, :not_allowed, allow} -> not_allowed(conn, allow)
    end
  end

  # Routing (before authentication, which needs the route's scope)

  defp route("GET", [endpoint]) when endpoint in @reads,
    do: {:ok, %{action: {:read, endpoint}, scope: "runtime.read"}}

  defp route("POST", [action]) when action in ~w(create start stop restart),
    do: {:ok, %{action: String.to_existing_atom(action), scope: "runtime.write"}}

  defp route("PUT", ["config"]), do: {:ok, %{action: :update, scope: "runtime.write"}}
  defp route("DELETE", []), do: {:ok, %{action: :delete, scope: "runtime.delete"}}

  defp route(_method, path) do
    case allowed(path) do
      [] -> {:error, 404, "not_found", "No runtime route has this path."}
      allow -> {:error, :not_allowed, allow}
    end
  end

  defp allowed([]), do: ["DELETE"]
  defp allowed(["config"]), do: ["GET", "PUT"]
  defp allowed([endpoint]) when endpoint in @reads, do: ["GET"]
  defp allowed([action]) when action in ~w(create start stop restart), do: ["POST"]
  defp allowed(_path), do: []

  # Authentication: a bearer credential of the runtime's owner with the
  # route's scope (force stop's extra scope is checked with its body).

  defp authenticate(conn, scope) do
    with {:ok, token} <- Macus.Auth.bearer_token(conn),
         {:ok, verified} <- verify(token),
         {:ok, state, uid} <- Macus.Auth.owner(),
         true <- verified.owner_key == Macus.Auth.owner_key(uid) do
      cond do
        scope not in verified.scopes ->
          {:error, 403, "forbidden", "The credential lacks the #{scope} scope."}

        Macus.Auth.Streams.register(verified.credential, verified.expires_at) != :ok ->
          {:error, 503, "unavailable", "The request cannot be tracked for revocation."}

        true ->
          {:ok, %{state: state, uid: uid, scopes: verified.scopes}}
      end
    else
      _ -> {:error, 401, "unauthorized", "A valid Macus bearer credential is required."}
    end
  end

  defp verify(token) do
    case Macus.Auth.Bearer.verify(token) do
      {:ok, %{owner_key: _, scopes: scopes, credential: _} = verified} when is_list(scopes) ->
        {:ok, verified}

      _ ->
        :error
    end
  end

  # Handling

  defp handle(conn, %{action: {:read, endpoint}}, owner) do
    with {:ok, conn} <- empty_or_ignored(conn) do
      dispatch(conn, owner, "GET", "/v1/runtime/#{endpoint}", "", @read_timeout, endpoint)
    end
  end

  defp handle(conn, %{action: action}, owner) when action in [:create, :update] do
    {method, path} =
      if action == :create,
        do: {"POST", "/v1/runtime/create"},
        else: {"PUT", "/v1/runtime/config"}

    with {:ok, conn, body} <- read(conn),
         :ok <- configuration(body, conn) do
      dispatch(conn, owner, method, path, body, @mutation_timeout, nil)
    end
  end

  defp handle(conn, %{action: :start}, owner) do
    with {:ok, conn, body} <- read(conn),
         {:ok, timeout} <- start_budget(body, conn) do
      dispatch(conn, owner, "POST", "/v1/runtime/start", body, timeout, nil)
    end
  end

  defp handle(conn, %{action: :restart}, owner) do
    with {:ok, conn, body} <- read(conn),
         :ok <- empty(body, conn) do
      dispatch(conn, owner, "POST", "/v1/runtime/restart", "", @mutation_timeout, nil)
    end
  end

  defp handle(conn, %{action: :stop}, owner) do
    with {:ok, conn, body} <- read(conn),
         {:ok, private} <- stop_body(body, owner, conn) do
      dispatch(conn, owner, "POST", "/v1/runtime/stop", private, @stop_timeout, nil)
    end
  end

  defp handle(conn, %{action: :delete}, owner) do
    with {:ok, conn, body} <- read(conn),
         :ok <- confirmed(body, "delete-runtime", conn) do
      dispatch(conn, owner, "DELETE", "/v1/runtime", ~s({"confirm":true}), @stop_timeout, nil)
    end
  end

  # Bodies

  defp read(conn) do
    case read_body(conn, length: @body_limit, read_length: 65_536, read_timeout: 15_000) do
      {:ok, body, conn} ->
        {:ok, conn, body}

      {:more, _partial, conn} ->
        error(
          conn,
          413,
          "payload_too_large",
          "Runtime request bodies are at most 1 MiB.",
          "not_dispatched"
        )

      {:error, _reason} ->
        error(
          conn,
          400,
          "invalid_request",
          "The request body could not be read.",
          "not_dispatched"
        )
    end
  end

  defp empty_or_ignored(conn) do
    case read(conn) do
      {:ok, conn, ""} -> {:ok, conn}
      {:ok, conn, _body} -> invalid(conn, "This request takes no body.")
      halted -> halted
    end
  end

  defp empty("", _conn), do: :ok
  defp empty(_body, conn), do: invalid(conn, "This request takes no body.")

  defp configuration(body, conn) do
    with {:ok, %{} = config} <- Jason.decode(body),
         [] <- Map.keys(config) -- Map.keys(Map.merge(@config_fields, @optional_config_fields)),
         true <- Enum.all?(@config_fields, fn {key, type} -> typed?(config, key, type) end),
         true <-
           Enum.all?(@optional_config_fields, fn {key, type} ->
             not Map.has_key?(config, key) or typed?(config, key, type)
           end) do
      :ok
    else
      _ ->
        error(
          conn,
          400,
          "invalid_configuration",
          "A complete schema 1 runtime configuration object is required.",
          "not_dispatched"
        )
    end
  end

  defp typed?(config, key, :integer), do: is_integer(Map.get(config, key))
  defp typed?(config, key, :string), do: is_binary(Map.get(config, key))
  defp typed?(config, key, :boolean), do: is_boolean(Map.get(config, key))
  defp typed?(config, key, :nullable_string), do: is_nil(config[key]) or is_binary(config[key])

  defp typed?(config, key, :shares) do
    case Map.get(config, key) do
      shares when is_list(shares) -> Enum.all?(shares, &share?/1)
      _ -> false
    end
  end

  defp share?(%{"name" => name, "path" => path} = share)
       when is_binary(name) and is_binary(path) do
    Map.keys(share) -- ["name", "path", "read_only"] == [] and
      (not Map.has_key?(share, "read_only") or is_boolean(share["read_only"]))
  end

  defp share?(_share), do: false

  # The deadline covers a valid budget plus a margin; Swift validates it.
  defp start_budget("", _conn), do: {:ok, @mutation_timeout}

  defp start_budget(body, conn) do
    case Jason.decode(body) do
      {:ok, %{"remaining_seconds" => seconds} = budget} when map_size(budget) == 1 ->
        if is_integer(seconds) and seconds in 1..3_600,
          do: {:ok, min((seconds + 30) * 1_000, @mutation_timeout)},
          else: {:ok, @read_timeout}

      _ ->
        invalid(conn, ~s(start takes an empty body or {"remaining_seconds": N}.))
    end
  end

  defp stop_body(body, owner, conn) do
    case if(body == "", do: {:ok, %{}}, else: Jason.decode(body)) do
      {:ok, stop} when stop == %{} or stop == %{"force" => false} ->
        {:ok, ~s({"force":false})}

      {:ok, %{"force" => true} = stop} when map_size(stop) <= 2 ->
        cond do
          stop["confirm"] !== "force-stop" ->
            error(
              conn,
              400,
              "confirmation_required",
              ~s(Set confirm to "force-stop" to force a stop.),
              "not_dispatched"
            )

          "runtime.delete" not in owner.scopes ->
            error(
              conn,
              403,
              "forbidden",
              "The credential lacks the runtime.delete scope.",
              "not_dispatched"
            )

          true ->
            {:ok, ~s({"force":true})}
        end

      _ ->
        invalid(conn, ~s(stop takes an empty body or {"force": false}.))
    end
  end

  defp confirmed(body, token, conn) do
    case Jason.decode(body) do
      {:ok, %{"confirm" => ^token} = confirm} when map_size(confirm) == 1 ->
        :ok

      _ ->
        error(
          conn,
          400,
          "confirmation_required",
          ~s(Set confirm to "#{token}".),
          "not_dispatched"
        )
    end
  end

  defp invalid(conn, message),
    do: error(conn, 400, "invalid_request", message, "not_dispatched")

  # Dispatch: one private request, never retried.

  defp dispatch(conn, owner, method, path, body, timeout, endpoint) do
    response =
      with {:ok, client} <- Client.new(owner.state, owner.uid) do
        Client.request(client, method, path, body, timeout_ms: timeout)
      end

    case response do
      {:ok, %Response{status: status, body: bytes}} ->
        send_resp(conn, status, project(status, bytes)) |> halt()

      {:error, %Error{code: code, outcome: outcome}} ->
        status = if code == :timeout, do: 504, else: 503
        code = if code == :timeout, do: "timeout", else: "unavailable"
        message = "The Swift runtime service did not answer."
        extra = if endpoint == "status", do: %{"server_ready" => true, "runtime_ready" => false}
        error(conn, status, code, message, Atom.to_string(outcome), extra || %{})
    end
  end

  # A runtime status object loses its private socket path and gains the
  # gateway's public endpoint and readiness.
  defp project(status, bytes) when status in 200..299 do
    case Jason.decode(bytes) do
      {:ok, %{"incus_socket" => _, "state" => state} = runtime} ->
        endpoint = endpoint()

        runtime
        |> Map.delete("incus_socket")
        |> Map.merge(%{
          "server_endpoint" => endpoint,
          "incus_endpoint" => endpoint && Map.take(endpoint, ["url", "certificate_fingerprint"]),
          "server_ready" => true,
          "runtime_ready" => state == "ready"
        })
        |> Jason.encode!()

      _ ->
        bytes
    end
  end

  defp project(_status, bytes), do: bytes

  defp endpoint do
    case Macus.Gateway.current() do
      %Macus.Gateway{config: config, certificate: certificate} ->
        %{"url" => config.url, "certificate_fingerprint" => certificate.fingerprint}

      nil ->
        nil
    end
  end

  defp not_allowed(conn, allow) do
    conn
    |> put_resp_header("allow", Enum.join(allow, ", "))
    |> error(405, "method_not_allowed", "Use #{Enum.join(allow, " or ")}.", "not_dispatched")
  end

  defp error(conn, status, code, message, outcome, extra \\ %{}) do
    body =
      Map.merge(
        %{"error" => %{"code" => code, "message" => message, "outcome" => outcome}},
        extra
      )

    conn |> send_resp(status, Jason.encode!(body)) |> halt()
  end
end
