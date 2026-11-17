defmodule MacusWeb.MCP do
  @moduledoc """
  Mounts the TamaMCP Streamable HTTP transport at exactly `/mcp`.

  The router forwards `/mcp` here; any longer path is not found, so the
  server has one MCP endpoint. The transport reads and bounds its own body
  (1 MiB), authenticates every request with `Macus.MCP.Authorization` and
  serves `Macus.MCP.Server`. No task store, runner or notification adapter
  is configured, so no task or subscription capability is advertised.

  The transport runtime is built and validated once, on first use, rather
  than at router compile time.
  """

  @behaviour Plug

  import Plug.Conn

  alias TamaMCP.Transport.StreamableHTTP.Plug, as: Transport

  @options [
    server: Macus.MCP.Server,
    authorization: Macus.MCP.Authorization,
    cache: Macus.MCP.Cache,
    telemetry_prefix: [:macus, :mcp]
  ]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: []} = conn, _opts), do: Transport.call(conn, runtime())

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, ~s({"errors":{"detail":"Not Found"}}))
    |> halt()
  end

  @doc "The validated transport runtime."
  def runtime do
    case :persistent_term.get({__MODULE__, :runtime}, nil) do
      nil ->
        runtime = Transport.init(@options)
        :persistent_term.put({__MODULE__, :runtime}, runtime)
        runtime

      runtime ->
        runtime
    end
  end
end
