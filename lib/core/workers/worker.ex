defmodule Core.Workers.Worker do
  @moduledoc """
  Background job worker. Polls the JobQueue every `@poll_interval` ms,
  claims the next available job, executes it, and updates its status.

  Designed to run in a pool via `Core.Workers.WorkerPool`. Each worker
  process operates independently — there is no cross-worker coordination
  needed because `JobQueue` serializes `claim_next/1` via `GenServer.call`.

  ## Custom workers

  To create a domain-specific worker, copy this module and override
  `perform_work/1`. You must keep the same `start_link/1` signature so
  `WorkerPool` can start it. The worker should read `:id` and `:pool` from
  `opts` and register under a unique name derived from the pool.

  ## Options (passed by WorkerPool)

    * `:id` – unique integer ID within the pool
    * `:queue` – the `JobQueue` name to poll (default: `Core.Workers.JobQueue`)
    * `:pool` – the `WorkerPool` name this worker belongs to

  ## Execution flow

  1. The worker receives `:work_available` (immediate wake-up from `JobQueue`)
     or `:work` (fallback timer every `@poll_interval` ms).
  2. It calls `JobQueue.claim_next/1` to atomically claim the next `:queued` job.
  3. It calls `perform_work/1` with the job struct — **this is your hook**.
  4. On success it calls `JobQueue.mark_done/3`; on exception it calls
     `JobQueue.mark_failed/3`.

  ## Telemetry events emitted

  - `[:core, :job, :start]`  — when a job begins executing
      metadata: `%{job_id: id, attempt: n, payload: map}`
  - `[:core, :job, :stop]`   — when a job completes successfully
      measurements: `%{duration: native_time}`
      metadata: `%{job_id: id}`
  - `[:core, :job, :error]`  — when a job raises an exception
      measurements: `%{duration: native_time}`
      metadata: `%{job_id: id, error: string}`
  """
  use GenServer
  require Logger
  alias Core.Workers.JobQueue
  alias Core.Telemetry.Events

  # 1 second fallback poll interval
  @poll_interval 1_000

  ## ============================================================
  ## Public API
  ## ============================================================

  def start_link(opts \\ []) do
    worker_id = Keyword.get(opts, :id, 1)
    pool_name = Keyword.get(opts, :pool, Core.Workers.WorkerPool)
    name = :"#{pool_name}_Worker_#{worker_id}"
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  ## ============================================================
  ## GenServer Callbacks
  ## ============================================================

  @impl true
  def init(opts) do
    worker_id = Keyword.get(opts, :id, 1)
    queue = Keyword.get(opts, :queue, Core.Workers.JobQueue)
    pool = Keyword.get(opts, :pool, Core.Workers.WorkerPool)

    Logger.info("Worker ##{worker_id} started (queue: #{inspect(queue)}, pool: #{inspect(pool)})")
    schedule_work()
    {:ok, %{id: worker_id, queue: queue, pool: pool}}
  end

  @impl true
  def handle_info(:work, state) do
    do_work(state)
    schedule_work()
    {:noreply, state}
  end

  @impl true
  def handle_info(:work_available, state) do
    # Woken by JobQueue when new work is available — try immediately
    do_work(state)
    schedule_work()
    {:noreply, state}
  end

  ## ============================================================
  ## Private Functions
  ## ============================================================

  defp schedule_work do
    Process.send_after(self(), :work, @poll_interval)
  end

  defp do_work(%{queue: queue} = state) do
    case JobQueue.claim_next(queue) do
      {:ok, job} -> execute(job, state)
      :empty -> :noop
    end
  end

  defp execute(job, %{id: worker_id, queue: queue}) do
    Logger.info("Worker ##{worker_id} executing job #{job.id} (attempt #{job.attempt})")

    :telemetry.execute(
      Events.job_start(),
      %{},
      %{job_id: job.id, attempt: job.attempt, payload: job.payload}
    )

    start_time = System.monotonic_time()

    try do
      result = perform_work(job)
      duration = System.monotonic_time() - start_time

      :telemetry.execute(
        Events.job_stop(),
        %{duration: duration},
        %{job_id: job.id}
      )

      # Protect against JobQueue being down during supervisor shutdown
      try do
        JobQueue.mark_done(queue, job.id, result)
      catch
        :exit, {:noproc, _} ->
          Logger.warning("Worker ##{worker_id} could not mark_done: JobQueue is down")
      end

      Logger.info("Worker ##{worker_id} completed job #{job.id} in #{native_to_ms(duration)}ms")
    rescue
      error ->
        duration = System.monotonic_time() - start_time
        message = Exception.message(error)

        :telemetry.execute(
          Events.job_error(),
          %{duration: duration},
          %{job_id: job.id, error: message}
        )

        error_details = %{
          error: message,
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        }

        Logger.error("Worker ##{worker_id} failed job #{job.id}: #{message}")

        # Protect against JobQueue being down during supervisor shutdown
        try do
          JobQueue.mark_failed(queue, job.id, error_details)
        catch
          :exit, {:noproc, _} ->
            Logger.warning("Worker ##{worker_id} could not mark_failed: JobQueue is down")
        end
    end
  end

  def perform_work(job) do
    # Placeholder for actual job execution logic
    # In a real application, this would dispatch to different handlers
    # based on job type
    Process.sleep(100)

    %{
      status: "completed",
      job_id: job.id,
      processed_at: DateTime.utc_now()
    }
  end

  defp native_to_ms(native) do
    System.convert_time_unit(native, :native, :millisecond)
  end
end
