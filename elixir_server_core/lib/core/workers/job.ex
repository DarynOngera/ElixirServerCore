defmodule Core.Workers.Job do 
  @enforce_keys [:id, :payload, :inserted_at]
  defstruct [:id, :payload, :inserted_at]
end 
