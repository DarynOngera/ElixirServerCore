# lib/core/workers/job_queue.ex
defmodule Core.Workers.JobQueue do
  use GenServer
  require Logger
  alias Core.Workers.Job

  ## ============================================================
  ## Client API
  ## ============================================================

  def start_link(_) do
    GenServer.start_link(__MODULE__, %{queue: :queue.new(), jobs: %{}}, name: __MODULE__)
  end

  @doc """
  Submit a new job to the queue
  """
  def submit(payload) do
    job = %Job{
      id: System.unique_integer([:positive]),
      payload: payload,
      inserted_at: DateTime.utc_now(),
      status: :queued
    }
    
    GenServer.cast(__MODULE__, {:enqueue, job})
    {:ok, job.id}
  end

  @doc """
  Claim the next available job for processing.
  Marks it as :running and returns it to the worker.
  """
  def claim_next do
    GenServer.call(__MODULE__, :claim_next)
  end

  @doc """
  Mark a job as completed with a result
  """
  def mark_done(id, result) do
    GenServer.call(__MODULE__, {:update_job, id, :done, result})
  end

  @doc """
  Mark a job as failed with an error reason
  """
  def mark_failed(id, reason) do
    GenServer.call(__MODULE__, {:update_job, id, :failed, reason})
  end

  @doc """
  Get all jobs in the queue
  """
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @doc """
  Get a specific job by ID
  """
  def get(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  ## ============================================================
  ## GenServer Callbacks
  ## ============================================================

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, job}, %{queue: queue, jobs: jobs}) do
    updated_queue = :queue.in(job.id, queue)
    updated_jobs = Map.put(jobs, job.id, job)
    
    {:noreply, %{queue: updated_queue, jobs: updated_jobs}}
  end

  @impl true
  def handle_call(:claim_next, _from, %{queue: queue, jobs: jobs} = state) do
    case find_next_queued_job(queue, jobs) do
      {:ok, job_id} ->
        job = Map.get(jobs, job_id)
        updated_job = %Job{job | 
          status: :running,
          started_at: DateTime.utc_now()
        }
        updated_jobs = Map.put(jobs, job_id, updated_job)
        
        {:reply, {:ok, updated_job}, %{state | jobs: updated_jobs}}
      
      :empty ->
        {:reply, :empty, state}
    end
  end

  @impl true
  def handle_call({:update_job, id, new_status, result}, _from, %{jobs: jobs} = state) do
    case Map.get(jobs, id) do
      nil ->
        {:reply, {:error, :not_found}, state}
      
      job ->
        updated_job = %Job{job |
          status: new_status,
          result: result,
          finished_at: DateTime.utc_now()
        }
        updated_jobs = Map.put(jobs, id, updated_job)
        
        {:reply, :ok, %{state | jobs: updated_jobs}}
    end
  end

  @impl true
  def handle_call(:all, _from, %{jobs: jobs} = state) do
    job_list = Map.values(jobs)
    {:reply, job_list, state}
  end

  @impl true
  def handle_call({:get, id}, _from, %{jobs: jobs} = state) do
    case Map.get(jobs, id) do
      nil -> {:reply, {:error, :not_found}, state}
      job -> {:reply, {:ok, job}, state}
    end
  end

  ## ============================================================
  ## Private Helpers
  ## ============================================================

  defp find_next_queued_job(queue, jobs) do
    queue
    |> :queue.to_list()
    |> Enum.find(fn job_id ->
      case Map.get(jobs, job_id) do
        %Job{status: :queued} -> true
        _ -> false
      end
    end)
    |> case do
      nil -> :empty
      job_id -> {:ok, job_id}
    end
  end
end
