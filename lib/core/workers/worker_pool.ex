defmodule Core.Workers.WorkerPool do
  @moduledoc """
  Supervisor that manages a pool of concurrent workers.

  Pool size defaults to the number of online schedulers (CPU cores).
  Configure via the `:worker_pool_size` application env:

      config :elixir_server_core, worker_pool_size: 4

  Or pass at startup:

      {Core.Workers.WorkerPool, size: 4}
  """
  use Supervisor
  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    size =
      Keyword.get(opts, :size) ||
        Application.get_env(:elixir_server_core, :worker_pool_size) ||
        System.schedulers_online()

    worker_module = Keyword.get(opts, :worker, Core.Workers.Worker)

    Code.ensure_loaded!(worker_module)

    unless function_exported?(worker_module, :start_link, 1) do
      raise ArgumentError,
            "#{inspect(worker_module)} must implement start_link/1 accepting [id: integer()]"
    end

    Logger.info("WorkerPool starting #{size} workers (module: #{worker_module})")

    children =
      for i <- 1..size do
        Supervisor.child_spec(
          {worker_module, [id: i]},
          id: {worker_module, i}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
