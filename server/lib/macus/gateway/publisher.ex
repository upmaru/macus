defmodule Macus.Gateway.Publisher do
  @moduledoc """
  Started after the gateway listener has bound its port: publishes the
  endpoint metadata and records the running gateway for `Macus.Proxy`.
  A failed publication stops startup.
  """

  use GenServer

  alias Macus.Gateway

  def start_link(gateway), do: GenServer.start_link(__MODULE__, gateway, name: __MODULE__)

  @impl true
  def init(%Gateway{} = gateway) do
    Process.flag(:trap_exit, true)

    case Gateway.publish(gateway, DateTime.utc_now()) do
      :ok ->
        Gateway.put_current(gateway)
        {:ok, gateway}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, _gateway), do: Gateway.clear_current()
end
