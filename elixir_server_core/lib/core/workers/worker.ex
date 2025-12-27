defmodule Core.Worker do 
  @moduledoc """
  Behaviour for all background workers.

  Workers must be deterministic, observable, and restartable.
  """

   @callback init(state :: term()) :: {:ok, term()}

   @callback handle_job(job :: term(), state :: term()) ::
               {:ok, term()}
               | {:retry, term()}
               | {:error, term()}
end
