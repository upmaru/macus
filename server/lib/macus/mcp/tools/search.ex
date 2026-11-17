defmodule Macus.MCP.Tools.Search do
  @moduledoc """
  The `search` tool: finds the operations the caller's verified scopes
  allow, ranked across every cassette, through `Tama.Dex.MCP.handle_search/3`
  (see `Macus.MCP.search/2`). Results only describe operations; running one
  still goes through `execute` and all its checks.
  """

  use Macus.MCP.DexTool, tool: :search_tool

  @impl TamaMCP.Tool
  def call(arguments, context) do
    arguments
    |> Macus.MCP.search(context)
    |> Macus.MCP.DexTool.respond()
  end
end
