defmodule Core.Workers.Worker do
  use GenServer
  require Logger
  alias Core.Workers.JobQueue

  @poll_interval 1_000  # 1 second

  ## ============================================================
  ## Public API
  ## ============================================================

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  ## ============================================================
  ## GenServer Callbacks
  ## ============================================================

  @impl true
  def init(state) do
    Logger.info("Worker started")
    schedule_work()
    {:ok, state}
  end

  @impl true
  def handle_info(:work, state) do
    case JobQueue.claim_next() do
      {:ok, job} ->
        execute(job)

      :empty ->
        # No jobs available, continue polling
        :noop
    end

    schedule_work()
    {:noreply, state}
  end

  ## ============================================================
  ## Private Functions
  ## ============================================================

  defp schedule_work do
    Process.send_after(self(), :work, @poll_interval)
  end

  defp execute(job) do
    Logger.info("Executing job #{job.id}")
    
    try do
      # Simulate actual work
      result = perform_work(job)
      
      JobQueue.mark_done(job.id, result)
      Logger.info("Job #{job.id} completed successfully")
    rescue
      error ->
        error_details = %{
          error: Exception.message(error),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        }
        
        Logger.error("Job #{job.id} failed: #{inspect(error)}")
        JobQueue.mark_failed(job.id, error_details)
    end
  end

  defp perform_work(job) do
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
end
