defmodule MacusWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Native gateway exchanges, from the shared library's stop event.
      # Tagged by protocol, admission kind and outcome only: path, project
      # and certificate are never metric tags.
      counter("opsmaru_incus.gateway.exchange.stop.count", exchange_options()),
      summary(
        "opsmaru_incus.gateway.exchange.stop.duration",
        exchange_options(unit: {:native, :millisecond})
      ),
      summary(
        "opsmaru_incus.gateway.exchange.stop.request_bytes",
        exchange_options(unit: :byte)
      ),
      summary(
        "opsmaru_incus.gateway.exchange.stop.response_bytes",
        exchange_options(unit: :byte)
      ),
      sum("macus.access_log.dropped.count"),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  @exchange_tags [:protocol, :admitted_as, :outcome]

  @doc "The only tags of the gateway exchange metrics."
  def exchange_tags, do: @exchange_tags

  defp exchange_options(options \\ []) do
    Keyword.merge([tags: @exchange_tags, tag_values: &exchange_tag_values/1], options)
  end

  @doc false
  def exchange_tag_values(metadata) do
    Map.new(@exchange_tags, fn tag ->
      value =
        case Map.get(metadata, tag) do
          nil -> "none"
          value when is_atom(value) -> Atom.to_string(value)
          value when is_binary(value) -> value
          _ -> "other"
        end

      {tag, value}
    end)
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3 and a metric must be added above.
      # {MacusWeb, :count_users, []}
    ]
  end
end
