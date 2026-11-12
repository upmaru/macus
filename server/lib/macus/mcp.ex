defmodule Macus.MCP do
  @moduledoc """
  Boundary for the Macus `/mcp` endpoint. It advertises exactly two
  maintained TamaMCP tools, `search` and `execute`, over one catalogue of
  `Opsmaru.Incus.Operations` descriptors and Macus-owned runtime operations.
  The tama-dex index (`Tama.Dex`) backs both tools; `execute` runs shared
  operations through `Opsmaru.Incus.Operations.run/3` with verified caller
  scopes and the Macus operations host. Operations are synchronous; durable
  MCP tasks are deferred.
  """
end
