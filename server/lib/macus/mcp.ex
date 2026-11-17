defmodule Macus.MCP do
  @moduledoc """
  Boundary for the Macus `/mcp` endpoint. It advertises exactly two
  maintained TamaMCP tools, `search` and `execute`, over one catalogue of
  `Opsmaru.Incus.Operations.Composite` descriptors and Macus-owned runtime
  operations. The tama-dex index (`Macus.Dex`) backs both tools; `execute`
  runs shared operations through `Opsmaru.Incus.Operations.Composite.run/3`
  with verified caller scopes and the Macus operations host. Operations are
  synchronous; durable MCP tasks are deferred.

  Native operations (`incus.native.*` scopes, source
  `opsmaru_incus_native`) stay hidden from every Macus caller this
  milestone: no executor is registered for them, and `caller/1` drops
  `incus.native.*` scopes before tama-dex sees the caller.
  """

  @native_prefix "incus.native."

  @doc """
  Executors by operation source. `opsmaru_incus` runs through
  `Macus.Dex.IncusExecutor`. `macus` gains `Macus.Dex.RuntimeExecutor` with
  task 7.2; until then its operations return `no_executor`. No executor is
  registered for `opsmaru_incus_native`.
  """
  @spec executors() :: %{String.t() => module() | {module(), keyword()}}
  def executors, do: %{"opsmaru_incus" => Macus.Dex.IncusExecutor}

  @doc "The caller as tama-dex and the executors see it: without `incus.native.*` scopes."
  @spec caller(TamaMCP.Context.t()) :: TamaMCP.Context.t()
  def caller(%TamaMCP.Context{scopes: scopes} = context) when is_list(scopes) do
    %{context | scopes: Enum.reject(scopes, &native_scope?/1)}
  end

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

  defp native_scope?(scope), do: is_binary(scope) and String.starts_with?(scope, @native_prefix)
end
