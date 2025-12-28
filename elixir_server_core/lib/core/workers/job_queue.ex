# lib/core/workers/job_queue.ex
defmodule Core.Workers.JobQueue do
  use GenServer
  require Logger

  alias Core.Workers.Job

  ## Client API

  def start_link(_) do
    GenServer.start_link(__MODULE__, :queue.new(), name: __MODULE__)
  end

  def submit(payload) do
    job = %Job{
      id: System.unique_integer([:positive]),
      payload: payload,
      inserted_at: System.monotonic_time()
    }

    GenServer.cast(__MODULE__, {:enqueue, job})
    {:ok, job.id}
  end

  def pop do
    GenServer.call(__MODULE__, :dequeue)
  end

  ## Server Callbacks

  @impl true
  def init(queue) do
    {:ok, queue}
  end

  @impl true
  def handle_cast({:enqueue, job}, queue) do
    {:noreply, :queue.in(job, queue)}
  end

  @impl true
  def handle_call(:dequeue, _from, queue) do
    case :queue.out(queue) do
      {{:value, job}, rest} ->
        {:reply, {:ok, job}, rest}

      {:empty, _} ->
        {:reply, :empty, queue}
    end
  end
end

