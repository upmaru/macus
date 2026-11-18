defmodule Macus.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # The public listener starts only when serving and after its preflight;
    # a failed preflight stops startup instead of falling back.
    case Macus.Gateway.serving() do
      {:ok, gateway} ->
        children =
          [
            MacusWeb.Telemetry,
            {Phoenix.PubSub, name: Macus.PubSub}
          ] ++
            Macus.Auth.Streams.child_specs() ++
            Macus.Proxy.child_specs() ++
            dex_children(gateway) ++
            [MacusWeb.Endpoint] ++
            Macus.Gateway.children(gateway)

        # See https://elixir.hexdocs.pm/Supervisor.html
        # for other strategies and supported options
        opts = [strategy: :one_for_one, name: Macus.Supervisor]
        Supervisor.start_link(children, opts)

      {:error, reason} ->
        Logger.error("Macus gateway did not start: " <> Macus.Gateway.describe(reason))
        {:error, {:gateway, reason}}
    end
  end

  # The operation index starts with the serving gateway, owned by its user
  # and under its state directory. Without a serving gateway it starts only
  # when explicitly enabled, so a default start opens or creates nothing. It
  # is a temporary child, so an index failure never stops the server.
  defp dex_children(%Macus.Gateway{} = gateway),
    do: Macus.Dex.children(Application.get_env(:macus, Macus.Dex, []), gateway)

  defp dex_children(nil) do
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
