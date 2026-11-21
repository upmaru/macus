defmodule Macus.MCP.Tools.Execute do
  @moduledoc """
  The `execute` tool: runs one operation, addressed by cassette and
  operation ID, through `Tama.Dex.MCP.handle_execute/4` with the caller's
  verified scopes and the Macus executors (see `Macus.MCP.execute/2`).
  """

  use Macus.MCP.DexTool, tool: :execute_tool

  @impl TamaMCP.Tool
  def call(arguments, context) do
    arguments
    |> Macus.MCP.execute(context)
    |> Macus.MCP.DexTool.respond()
  end
end
