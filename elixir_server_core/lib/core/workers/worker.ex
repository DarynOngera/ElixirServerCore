defmodule Core.Workers.Worker do
  use GenServer
  require Logger

  @poll_interval 1_000  # 1 second

  ## Public API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  ## GenServer callbacks

  @impl true
  def init(state) do
    Logger.info("Worker started")
    schedule_work()
    {:ok, state}
  end

  @impl true
  def handle_info(:work, state) do
    case Core.Workers.JobQueue.pop() do
      {:ok, job} ->
        execute(job)

      :empty ->
        :noop
    end

    schedule_work()
    {:noreply, state}
  end

  ## Internal functions

  defp schedule_work do
    Process.send_after(self(), :work, @poll_interval)
  end

  defp execute(job) do
    Logger.info("Executing job #{job.id}")
    # Placeholder for actual job execution
    :ok
  end
end

