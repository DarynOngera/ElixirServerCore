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
  def submit(payload, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)

    job = %Job{
      id: System.unique_integer([:positive, :monotonic]),
      payload: payload,
      inserted_at: DateTime.utc_now(),
      status: :queued,
      max_attempts: max_attempts
    }
    
    GenServer.cast(__MODULE__, {:enqueue, job})
    {:ok, job.id}
  end

   @doc """
  Submit a job to run at a specific future time.
  """
  def submit_at(payload, %DateTime{} = run_at, opts \\ []) do
    delay_ms = max(DateTime.diff(run_at, DateTime.utc_now(), :millisecond), 0)
    max_attempts = Keyword.get(opts, :max_attempts, 3)
 
    job = %Job{
      id: System.unique_integer([:positive, :monotonic]),
      payload: payload,
      inserted_at: DateTime.utc_now(),
      status: :queued,
      max_attempts: max_attempts
    }
 
    # Schedule delayed enqueue
    Process.send_after(__MODULE__, {:enqueue_delayed, job}, delay_ms)
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
    GenServer.call(__MODULE__, {:finish_job, id, :done, result})
  end

  @doc """
  Mark a job as failed with an error reason
  """
  def mark_failed(id, reason) do
    GenServer.call(__MODULE__, {:fail_job, id, :failed, reason})
  end

  @doc """
  Get all jobs in the queue
  """
  def all(opts \\ []) do
    GenServer.call(__MODULE__, :all, opts)
  end

  @doc """
  Get a specific job by ID
  """
  def get(id) do
    GenServer.call(__MODULE__, {:get, id})
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
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
    case dequeue_next_queued(queue, jobs) do 
      {:ok, job_id, remaining_queue} ->
        job = Map.fetch!(jobs, job_id)

        updated_job = %Job{job |
          status: :running,
          started_at: DateTime.utc_now(),
          attempt: job.attempt + 1
        }

        updated_jobs = Map.put(jobs, job_id, updated_job)
        new_state = %{state | queue: remaining_queue, jobs: updated_jobs}
        {:reply, {:ok, updated_job}, new_state}

      :empty -> 
        {:reply, :empty, state}
    end
  end

  @impl true
   def handle_call({:finish_job, id, status, result}, _from, %{jobs: jobs} = state) do
    case Map.get(jobs, id) do
      nil ->
        {:reply, {:error, :not_found}, state}
 
      job ->
        updated_job = %Job{job |
          status: status,
          result: result,
          finished_at: DateTime.utc_now()
        }
 
        updated_jobs = Map.put(jobs, id, updated_job)
        {:reply, :ok, %{state | jobs: updated_jobs}}
    end
  end

  @impl true
  def handle_call({:fail_job, id, reason}, _from, %{queue: queue, jobs: jobs} = state) do
    case Map.get(jobs, id) do
      nil ->
        {:reply, {:error, :not_found}, state}
 
      job ->
        if Job.retries_exhausted?(job) do
          # Permanently failed
          updated_job = %Job{job |
            status: :failed,
            result: reason,
            finished_at: DateTime.utc_now()
          }
 
          updated_jobs = Map.put(jobs, id, updated_job)
          {:reply, :ok, %{state | jobs: updated_jobs}}
        else
          # Schedule retry
          backoff = Job.backoff_ms(job)
          retry_at = DateTime.add(DateTime.utc_now(), backoff, :millisecond)
 
          updated_job = %Job{job |
            status: :queued,
            result: reason,
            retry_at: retry_at
          }
 
          updated_jobs = Map.put(jobs, id, updated_job)
 
          # Re-enqueue after backoff
          Process.send_after(self(), {:re_enqueue, id}, backoff)
 
          Logger.warning("Job #{id} failed (attempt #{job.attempt}/#{job.max_attempts}), retrying in #{backoff}ms")
          {:reply, :ok, %{state | jobs: updated_jobs}}
        end
    end
  end

  @impl true
  def handle_call({:all, opts}, _from, %{jobs: jobs} = state) do
    status_filter = Keyword.get(opts, :status)
    page = max(Keyword.get(opts, :page, 1), 1)
    per_page = min(Keyword.get(opts, :per_page, 50), 200)
 
    result =
      jobs
      |> Map.values()
      |> then(fn list ->
        if status_filter, do: Enum.filter(list, &(&1.status == status_filter)), else: list
      end)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.drop((page - 1) * per_page)
      |> Enum.take(per_page)
 
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get, id}, _from, %{jobs: jobs} = state) do
    case Map.get(jobs, id) do
      nil -> {:reply, {:error, :not_found}, state}
      job -> {:reply, {:ok, job}, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, %{jobs: jobs} = state) do
    counts =
      jobs
      |> Map.values()
      |> Enum.group_by(& &1.status)
      |> Map.new(fn {status, list} -> {status, length(list)} end)
 
    stats = %{
      queued: Map.get(counts, :queued, 0),
      running: Map.get(counts, :running, 0),
      done: Map.get(counts, :done, 0),
      failed: Map.get(counts, :failed, 0),
      total: map_size(jobs)
    }
 
    {:reply, stats, state}
  end
 
  @impl true
  def handle_info({:enqueue_delayed, job}, %{queue: queue, jobs: jobs} = state) do
    updated_queue = :queue.in(job.id, queue)
    updated_jobs = Map.put(jobs, job.id, job)
    {:noreply, %{state | queue: updated_queue, jobs: updated_jobs}}
  end
 
  @impl true
  def handle_info({:re_enqueue, id}, %{queue: queue, jobs: jobs} = state) do
    case Map.get(jobs, id) do
      %Job{status: :queued} = _job ->
        updated_queue = :queue.in(id, queue)
        {:noreply, %{state | queue: updated_queue}}
 
      _ ->
        # Job may have been cancelled or already processed
        {:noreply, state}
    end
  end
 
  @impl true
  def terminate(reason, %{jobs: jobs}) do
    Logger.warning("JobQueue terminating (#{inspect(reason)}), marking running jobs as failed")
 
    Enum.each(jobs, fn
      {_id, %Job{status: :running} = job} ->
        Logger.error("Job #{job.id} was :running at shutdown — marking :failed")
 
      _ ->
        :ok
    end)
 
    :ok
  end

  ## ============================================================
  ## Private Helpers
  ## ============================================================
  
  # Pops from the front of the queue until a :queued job is found.
  # Returns {:ok, job_id, remaining_queue} or :empty.
  # This is O(1) for the happy path (front of queue is :queued).

  defp dequeue_next_queued(queue, jobs) do
    case :queue.out(queue) do 
      {:empty, _} -> 
        :empty

      {{:value, job_id}, remaining} ->
        case Map.get(jobs, job_id) do
          %Job{status: :queued} ->
            {:ok, job_id, remaining}
      _ ->
        dequeue_next_queued(remaining, jobs)
        end
    end
  end 

end
