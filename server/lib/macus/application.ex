defmodule Macus.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        MacusWeb.Telemetry,
        {Phoenix.PubSub, name: Macus.PubSub}
      ] ++
        dex_children() ++
        [
          # Start to serve requests, typically the last entry
          MacusWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Macus.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The operation index starts only when explicitly enabled; a default start
  # stays passive and opens or creates nothing. It is a temporary child, so
  # an index failure never stops the server.
  defp dex_children do
    state =
      case Macus.Configuration.new(Application.get_env(:macus, :state_dir)) do
        {:ok, config} -> config
        {:error, _} -> nil
      end

    Macus.Dex.children(Application.get_env(:macus, Macus.Dex, []), state)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MacusWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
