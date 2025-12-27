defmodule ElixirServerCoreTest do
  use ExUnit.Case
  doctest ElixirServerCore

  test "greets the world" do
    assert ElixirServerCore.hello() == :world
  end
end
