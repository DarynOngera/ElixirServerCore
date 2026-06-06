defmodule Core.JobStore.Memory do
  @moduledoc """
  In-memory job store that retains jobs for the lifetime of the VM.

  Jobs are stored in an Agent and survive `JobQueue` restarts, but are
  lost when the entire VM exits. Suitable for prototyping and testing.

  ## Configuration

      config :servcore, :job_store, Core.JobStore.Memory
      config :servcore, :job_store_opts, max_age_days: 7
  """
  @behaviour Core.JobStore
  alias Core.Workers.Job

  @agent_name __MODULE__

  @impl true
  def init(_opts) do
    case Agent.start(fn -> %{} end, name: @agent_name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @impl true
  def insert_job(%Job{} = job) do
    id = System.unique_integer([:positive, :monotonic])
    job = %Job{job | id: id}
    Agent.update(@agent_name, &Map.put(&1, id, job))
    {:ok, job}
  end

  @impl true
  def update_job(id, changes) do
    Agent.update(@agent_name, fn jobs ->
      case Map.get(jobs, id) do
        nil -> jobs
        job -> Map.put(jobs, id, apply_changes(job, changes))
      end
    end)

    :ok
  end

  @impl true
  def get_job(id) do
    case Agent.get(@agent_name, &Map.get(&1, id)) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  @impl true
  def list_jobs(opts \\ []) do
    jobs = Agent.get(@agent_name, &Map.values/1)

    if status = Keyword.get(opts, :status) do
      Enum.filter(jobs, &(&1.status == status))
    else
      jobs
    end
  end

  @impl true
  def cleanup(opts) do
    max_age_days = Keyword.get(opts, :max_age_days, 7)
    cutoff = DateTime.add(DateTime.utc_now(), -max_age_days, :day)

    Agent.update(@agent_name, fn jobs ->
      Enum.reject(jobs, fn {_id, job} ->
        job.status in [:done, :failed] and
          not is_nil(job.finished_at) and
          DateTime.compare(job.finished_at, cutoff) == :lt
      end)
      |> Map.new()
    end)

    :ok
  end

  # -- Private --

  defp apply_changes(%Job{} = job, changes) do
    Enum.reduce(changes, job, fn
      {:status, v}, %Job{} = acc -> %{acc | status: v}
      {:attempt, v}, %Job{} = acc -> %{acc | attempt: v}
      {:result, v}, %Job{} = acc -> %{acc | result: v}
      {:retry_at, v}, %Job{} = acc -> %{acc | retry_at: v}
      {:run_at, v}, %Job{} = acc -> %{acc | run_at: v}
      {:started_at, v}, %Job{} = acc -> %{acc | started_at: v}
      {:finished_at, v}, %Job{} = acc -> %{acc | finished_at: v}
      _, %Job{} = acc -> acc
    end)
  end
end
