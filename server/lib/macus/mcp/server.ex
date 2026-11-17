defmodule Macus.MCP.Server do
  @moduledoc """
  The Macus TamaMCP server: exactly two tools, `search` and `execute`. No
  operation is advertised as its own tool, and both tools are synchronous,
  so no task capability is offered.

  TamaMCP takes literal options, so the version is written here; a test
  keeps it equal to the `:macus` project version.
  """

  use TamaMCP.Server,
    name: "macus",
    version: "0.1.0",
    instructions:
      "Use search to find an operation for the Macus VM or its Incus workloads, then run it with execute, passing the cassette, operation_id and an input matching its input_schema. An error with dispatched true may have taken effect: check state before trying again."

  tool Macus.MCP.Tools.Search, name: "search"
  tool Macus.MCP.Tools.Execute, name: "execute"
end
