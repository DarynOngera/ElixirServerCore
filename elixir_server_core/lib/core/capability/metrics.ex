defmodule Core.Capability.Metrics do
  alias Telemetry.Metrics

  def metrics do
    [
      Metrics.counter("server.http.request.count",
        event_name: [:server, :http, :stop]
      ),
      Metrics.last_value("server.http.request.duration",
        event_name: [:server, :http, :stop],
        measurement: :duration,
        unit: {:native, :millisecond}
      )
    ]
  end
end

