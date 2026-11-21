defmodule Macus.Dex.NativeExecutor do
  @moduledoc """
  The `Tama.Dex.Executor` for the `opsmaru_incus_native` source: runs one
  native client operation with `Opsmaru.Incus.Operations.Native.run/3`.

  Like `Macus.Dex.IncusExecutor`, the host is always `Macus.MCP.IncusHost`,
  the caller is `call.context` and the scopes are `call.scopes`. Native
  operations need `incus.native.*` scopes, which a Macus token carries only
  when its owner issued it with them; the composite `incus.*` scopes never
  imply them. Native certificate operations act on the guest's own Incus
  trust store, which never grants access to the gateway.
  """

  @behaviour Tama.Dex.Executor

  alias Opsmaru.Incus.Operations.Native

  @impl Tama.Dex.Executor
  def execute(%Tama.Dex.Call{} = call, input) do
    case Native.run(call.operation_id, input,
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
