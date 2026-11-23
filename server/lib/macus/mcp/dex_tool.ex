defmodule Macus.MCP.DexTool do
  @moduledoc """
  Builds the Macus `search` and `execute` TamaMCP tool modules from the
  tama-dex definitions.

  `TamaMCP.Tool` takes literal schemas, so `use Macus.MCP.DexTool, tool:
  :execute_tool` injects `Tama.Dex.MCP.execute_tool/0` (or `search_tool/0`)
  at compile time: its title, description, annotations and input/output
  schemas. The tools need no tool-level scope. tama-dex checks every
  operation against the caller's verified scopes, so a scope on the tool
  would only be an outer gate.
  """

  defmacro __using__(opts) do
    tool = apply(Tama.Dex.MCP, Keyword.fetch!(opts, :tool), [])

    quote do
      use TamaMCP.Tool,
        task: :disabled,
        scopes: [],
        title: unquote(tool.title),
        description: unquote(tool.description),
        annotations: unquote(Map.to_list(tool.annotations))

      raw_input_schema(unquote(Macro.escape(tool.input_schema)))
      raw_output_schema(unquote(Macro.escape(tool.output_schema)))
    end
  end

  @doc """
  Sends a tama-dex handler response as structured content. An `"error"`
  object, or an executor's own `"operation_error"` (always `"dispatched" =>
  true`), is a tool error; the caller reconciles a dispatched error rather
  than retrying.
  """
  @spec respond(map()) :: {:ok, TamaMCP.Response.t()}
  def respond(structured) when is_map(structured) do
    failed? = Map.has_key?(structured, "error") or Map.has_key?(structured, "operation_error")
    build = if failed?, do: &TamaMCP.Response.tool_error/1, else: &TamaMCP.Response.success/1

    {:ok,
     build.(
       structured_content: structured,
       content: [TamaMCP.Response.text(Jason.encode!(structured))]
     )}
  end
end
