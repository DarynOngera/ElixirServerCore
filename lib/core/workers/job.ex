defmodule Core.Workers.Job do
  @moduledoc """
  Immutable job record that flows through the queue lifecycle.

  ## Fields

  - `:id` — Assigned by the store (SQLite auto-increment or VM-local monotonic).
  - `:payload` — Arbitrary map supplied by the caller at submission time.
  - `:status` — One of `:queued`, `:running`, `:done`, `:failed`.
  - `:attempt` — Number of times this job has been claimed by a worker (starts at 0).
  - `:max_attempts` — Total claim attempts before the job is permanently failed (default: 3).
  - `:retry_at` — When the next retry is scheduled. `nil` unless job is waiting to retry.
  - `:run_at` — When a scheduled job should enter the in-memory queue. `nil` means immediate.
  - `:inserted_at`, `:started_at`, `:finished_at` — UTC timestamps for each lifecycle stage.

  ## Lifecycle

      :queued → :running → :done
                          ↘ :failed (retries_exhausted? or unrecoverable)
                          ↘ :queued (retry scheduled via backoff)
  """
  @derive Jason.Encoder
  @enforce_keys [:payload, :inserted_at]
  defstruct [
    :id,
    :payload,
    :inserted_at,
    :started_at,
    :finished_at,
    :result,
    :retry_at,
    :run_at,
    status: :queued,
    attempt: 0,
    max_attempts: 3
  ]

  @type status :: :queued | :running | :done | :failed
  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          payload: map(),
          inserted_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          result: map() | nil,
          retry_at: DateTime.t() | nil,
          run_at: DateTime.t() | nil,
          status: status(),
          attempt: non_neg_integer(),
          max_attempts: pos_integer()
        }

  @doc """
  Deserialize a raw map (e.g. from a database row) into a %Job{} struct.
  Handles JSON string → map for payload/result and ISO8601 → DateTime.
  """
  def from_map(attrs) when is_map(attrs) do
    %__MODULE__{
      id: attrs[:id],
      payload: decode_json(attrs[:payload]) || %{},
      status: parse_status(attrs[:status]),
      attempt: attrs[:attempt] || 0,
      max_attempts: attrs[:max_attempts] || 3,
      result: decode_json(attrs[:result]),
      retry_at: parse_datetime(attrs[:retry_at]),
      run_at: parse_datetime(attrs[:run_at]),
      inserted_at: parse_datetime!(attrs[:inserted_at]),
      started_at: parse_datetime(attrs[:started_at]),
      finished_at: parse_datetime(attrs[:finished_at])
    }
  end

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

  # -- Private Helpers --

  defp decode_json(nil), do: nil

  defp decode_json(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, decoded} -> decoded
      _ -> nil
    end
  end

  defp decode_json(map) when is_map(map), do: map

  defp parse_status(nil), do: :queued
  defp parse_status(status) when is_atom(status), do: status

  defp parse_status(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> :queued
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime!(nil), do: nil
  defp parse_datetime!(%DateTime{} = dt), do: dt

  defp parse_datetime!(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> raise ArgumentError, "invalid datetime: #{inspect(str)}"
    end
  end
end
