defmodule MacusWeb.TelemetryTest do
  use ExUnit.Case, async: true

  @stop [:opsmaru_incus, :gateway, :exchange, :stop]

  test "exchange metrics are tagged by protocol, admission kind and outcome only" do
    exchange = Enum.filter(MacusWeb.Telemetry.metrics(), &(&1.event_name == @stop))

    assert Enum.map(exchange, &{&1.__struct__, List.last(&1.name)}) == [
             {Telemetry.Metrics.Counter, :count},
             {Telemetry.Metrics.Summary, :duration},
             {Telemetry.Metrics.Summary, :request_bytes},
             {Telemetry.Metrics.Summary, :response_bytes}
           ]

    for metric <- exchange do
      assert metric.tags == [:protocol, :admitted_as, :outcome]

      tags =
        metric.tag_values.(%{
          protocol: :websocket,
          admitted_as: nil,
          outcome: :ok,
          path: "/1.0/instances/web",
          project: "default",
          peer_fingerprint: String.duplicate("a", 64)
        })

      assert tags == %{protocol: "websocket", admitted_as: "none", outcome: "ok"}
    end
  end

  test "dropped access records are summed" do
    assert Enum.any?(
             MacusWeb.Telemetry.metrics(),
             &(&1.event_name == [:macus, :access_log, :dropped] and &1.measurement == :count)
           )
  end
end
