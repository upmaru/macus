defmodule Macus.Dex.IncusExecutor do
  @moduledoc """
  The `Tama.Dex.Executor` for the `opsmaru_incus` source: runs the shared
  operation with `Opsmaru.Incus.Operations.Composite.run/3`.

  The host is always `Macus.MCP.IncusHost` and the caller is `call.context`,
  the verified `TamaMCP.Context`. The scopes are `call.scopes`, exactly those
  tama-dex checked, never re-derived. A shared operation's error is
  returned as `%{"error" => error}`, the shape its document declares, so
  tama-dex reports it as the operation's own error with `"dispatched" =>
  true`.
  """

  @behaviour Tama.Dex.Executor

  alias Opsmaru.Incus.Operations.Composite

  @impl Tama.Dex.Executor
  def execute(%Tama.Dex.Call{} = call, input) do
    case Composite.run(call.operation_id, input,
           host: Macus.MCP.IncusHost,
           caller: call.context,
           scopes: call.scopes
         ) do
      {:ok, result} -> {:ok, result}
      {:error, %{"kind" => _} = error} -> {:error, %{"error" => error}}
      other -> other
    end
  end
end
