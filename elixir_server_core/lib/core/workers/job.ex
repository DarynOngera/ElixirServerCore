defmodule Core.Workers.Job do
  @derive Jason.Encoder
  @enforce_keys [:id, :payload, :inserted_at]
  defstruct [
    :id, 
    :payload, 
    :inserted_at, # :pending | :running |:done | :failed
    :started_at,
    :finished_at,
    :result,
    status: :queued
  ]
end 
