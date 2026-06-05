defmodule Core.Workers.Job do

  @moduledoc """
Immutable job record that flows through the queue lifecycle.

## Fields

- `:id` — Monotonically increasing positive integer, unique per VM boot.
- `:payload` — Arbitrary map supplied by the caller at submission time.
- `:status` — One of `:queued`, `:running`, `:done`, `:failed`.
- `:attempt` — Number of times this job has been claimed by a worker (starts at 0).
- `:max_attempts` — Total claim attempts before the job is permanently failed (default: 3).
- `:retry_at` — When the next retry is scheduled. `nil` unless job is waiting to retry.
- `:inserted_at`, `:started_at`, `:finished_at` — UTC timestamps for each lifecycle stage.

## Lifecycle

    :queued → :running → :done
                       ↘ :failed (retries_exhausted? or unrecoverable)
                       ↘ :queued (retry scheduled via backoff)
"""
  @derive Jason.Encoder
  @enforce_keys [:id, :payload, :inserted_at]
  defstruct [
    :id, 
    :payload, 
    :inserted_at,
    :started_at,
    :finished_at,
    :result,
    :retry_at,
    status: :queued,
    attempt: 0,
    max_attempts: 3    
  ]

  @type status :: :queued | :running | :done | :failed
  @type t :: %__MODULE__{
    id: pos_integer(),
    payload: map(),
    inserted_at: DateTime.t(),
    started_at: DateTime.t() | nil,
    finished_at: DateTime.t() | nil,
    result: map() | nil,
    retry_at: DateTime.t() | nil,
    status: status(),
    attempt: non_neg_integer(),
    max_attempts: pos_integer()
  }

  @doc """
  Returns true if job has exhausted all retry attempts
  """
  def retries_exhausted?(%__MODULE__{attempt: a, max_attempts: m}), do: a >= m

  @doc """
  Calculates the next retry delay using exponential backoff.
  Returns milliseconds.
  """
  def backoff_ms(%__MODULE__{attempt: attempt}) do
    # 1s, 2s, 4s, 8s, ... capped at 30s
    min(trunc(:math.pow(2, attempt) * 1_000), 30_000)
  end
end 
