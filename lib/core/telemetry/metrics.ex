defmodule Core.Telemetry.Metrics do
  alias Telemetry.Metrics

  def metrics do
    [
      Metrics.counter("core.job.count",
        event_name: [:core, :job, :stop]
      ),

      Metrics.summary("core.job.duration",
        event_name: [:core, :job, :stop],
        measurement: :duration,
        unit: {:native, :millisecond}
      )
    ]
  end
end

