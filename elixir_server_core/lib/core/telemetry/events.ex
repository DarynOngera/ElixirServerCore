defmodule Core.Telemetry.Events do 
  @job_start [:core, :job, :start]
  @job_stop [:core, :job, :stop]
  @job_error [:core, :job, :error]

  def job_start, do: @job_start
  def job_stop, do: @job_stop
  def job_error, do: @job_error
end 

