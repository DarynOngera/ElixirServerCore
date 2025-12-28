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
      inserted_at: DateTime.utc_now(),
      status: :queued,
      result: nil,
      started_at: nil,
      finished_at: nil
    }

    GenServer.cast(__MODULE__, {:enqueue, job})
    {:ok, job.id}
  end

  def pop do
    GenServer.call(__MODULE__, :dequeue)
  end

  def mark_running(id), do: update_status(id, :running)
  def mark_done(id, result), do: update_status(id, :done, result)
  def mark_failed(id, reason), do: update_status(id, :failed, reason)

  ## Server Callbacks

  @impl true
  def init(queue), do: {:ok, queue}

  @impl true
  def handle_cast({:enqueue, job}, queue), do: {:noreply, :queue.in(job, queue)}

  @impl true
  def handle_call(:dequeue, _from, queue) do
    case :queue.out(queue) do
      {{:value, job}, rest} -> {:reply, {:ok, job}, rest}
      {:empty, _} -> {:reply, :empty, queue}
    end
  end

  # Private helper to update job status
  defp update_status(id, new_status, result \\ nil) do
    GenServer.call(__MODULE__, {:update_status, id, new_status, result})
  end

  @impl true
  def handle_call({:update_status, id, new_status, result}, _from, queue) do
    {found, updated_queue} =
      :queue.fold({false, :queue.new()}, fn job, {found_acc, q_acc} ->
        if job.id == id do
          updated_job = %Job{
            job
            | status: new_status,
              result: result,
              started_at: if(new_status == :running, do: DateTime.utc_now(), else: job.started_at),
              finished_at: if(new_status in [:done, :failed], do: DateTime.utc_now(), else: job.finished_at)
          }

          {true, :queue.in(updated_job, q_acc)}
        else
          {found_acc, :queue.in(job, q_acc)}
        end
      end, {false, :queue.new()} |> elem(1))

    if found, do: {:reply, :ok, updated_queue}, else: {:reply, {:error, :not_found}, queue}
  end
 def all do
   GenServer.call(__MODULE__, :all)
 end

 @impl true
 def handle_call(:all, _from, queue) do
   jobs = :queue.to_list(queue)
   {:reply, jobs, queue}
 end
end

