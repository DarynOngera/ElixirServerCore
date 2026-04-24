defmodule Core.Telemetry.Events do
  @moduledoc """
  Telemetry event name constants and emit helpers for Elixir Server Core.

  ## Events

  | Event                    | Emitted when                         |
  |--------------------------|--------------------------------------|
  | `[:core, :job, :start]`  | A worker begins executing a job      |
  | `[:core, :job, :stop]`   | A job completes successfully         |
  | `[:core, :job, :error]`  | A job raises an exception            |

  ## Attaching handlers

      :telemetry.attach_many(
        "my-handler",
        [Core.Telemetry.Events.job_start(), Core.Telemetry.Events.job_stop()],
        &MyApp.Telemetry.handle_event/4,
        nil
      )
  """

  @job_start [:core, :job, :start]
  @job_stop  [:core, :job, :stop]
  @job_error [:core, :job, :error]

  def job_start, do: @job_start
  def job_stop,  do: @job_stop
  def job_error, do: @job_error

  @doc """
  Emit job_start. Called by the worker before performing work.
  """
  def emit_job_start(job_id, attempt, payload) do
    :telemetry.execute(@job_start, %{}, %{job_id: job_id, attempt: attempt, payload: payload})
  end

  @doc """
  Emit job_stop. Called by the worker on success.
  """
  def emit_job_stop(job_id, duration_native) do
    :telemetry.execute(@job_stop, %{duration: duration_native}, %{job_id: job_id})
  end

  @doc """
  Emit job_error. Called by the worker on exception.
  """
  def emit_job_error(job_id, duration_native, error_message) do
    :telemetry.execute(@job_error, %{duration: duration_native}, %{job_id: job_id, error: error_message})
  end
end
