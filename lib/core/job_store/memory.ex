defmodule Core.JobStore.Memory do
  @moduledoc """
  Default no-op store. Assigns VM-local monotonic IDs but does not persist.
  Jobs are lost on VM restart.
  """
  @behaviour Core.JobStore
  alias Core.Workers.Job

  @impl true
  def init(_opts), do: :ok

  @impl true
  def insert_job(%Job{} = job) do
    id = System.unique_integer([:positive, :monotonic])
    job = %Job{job | id: id}
    {:ok, job}
  end

  @impl true
  def update_job(_id, _changes), do: :ok

  @impl true
  def get_job(_id), do: {:error, :not_found}

  @impl true
  def list_jobs(_opts), do: []

  @impl true
  def cleanup(_opts), do: :ok
end
