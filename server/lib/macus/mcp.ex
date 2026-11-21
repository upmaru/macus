defmodule Macus.MCP do
  @moduledoc """
  Boundary for the Macus `/mcp` endpoint. It advertises exactly two
  maintained TamaMCP tools, `search` and `execute`, over one catalogue of
  `Opsmaru.Incus.Operations.Composite` descriptors and Macus-owned runtime
  operations. The tama-dex index (`Macus.Dex`) backs both tools; `execute`
  runs shared operations through `Opsmaru.Incus.Operations.Composite.run/3`
  with verified caller scopes and the Macus operations host. Operations are
  synchronous; durable MCP tasks are deferred.

  Native operations (source `opsmaru_incus_native`) run through
  `Macus.Dex.NativeExecutor` and need `incus.native.*` scopes. A token
  carries those only when its owner issued it with them explicitly; the
  composite `incus.*` scopes never imply them, so a caller without them can
  neither find nor run a native operation.
  """

  @doc """
  Executors by operation source: `opsmaru_incus` runs through
  `Macus.Dex.IncusExecutor`, `opsmaru_incus_native` through
  `Macus.Dex.NativeExecutor` and `macus` through `Macus.Dex.RuntimeExecutor`.
  """
  @spec executors() :: %{String.t() => module() | {module(), keyword()}}
  def executors,
    do: %{
      "opsmaru_incus" => Macus.Dex.IncusExecutor,
      "opsmaru_incus_native" => Macus.Dex.NativeExecutor,
      "macus" => Macus.Dex.RuntimeExecutor
    }

  @doc "The caller as tama-dex and the executors see it: its verified scopes, or none."
  @spec caller(TamaMCP.Context.t()) :: TamaMCP.Context.t()
  def caller(%TamaMCP.Context{scopes: scopes} = context) when is_list(scopes), do: context
  def caller(%TamaMCP.Context{} = context), do: %{context | scopes: []}

  @doc """
  Handles a `search` call for a verified TamaMCP context. Returns the
  tama-dex response map; `not_ready` when the operation index is not
  running.
  """
  @spec search(map(), TamaMCP.Context.t(), GenServer.server()) :: map()
  def search(arguments, %TamaMCP.Context{} = context, index \\ Macus.Dex.index()) do
    Tama.Dex.MCP.handle_search(index, arguments, caller(context))
  catch
    :exit, _reason -> unavailable()
  end

  @doc """
  Handles an `execute` call for a verified TamaMCP context. Returns the
  tama-dex response map; `not_ready` with `"dispatched" => false` when the
  operation index is not running.
  """
  @spec execute(map(), TamaMCP.Context.t(), GenServer.server()) :: map()
  def execute(arguments, %TamaMCP.Context{} = context, index \\ Macus.Dex.index()) do
    Tama.Dex.MCP.handle_execute(index, arguments, caller(context), executors())
  catch
    :exit, _reason -> unavailable()
  end

  defp unavailable do
    %{
      "error" => %{
        "kind" => "not_ready",
        "dispatched" => false,
        "message" => "The operation index is not available. Try again shortly."
      }
    }
  end
end
