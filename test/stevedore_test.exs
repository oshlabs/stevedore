defmodule StevedoreTest do
  use ExUnit.Case
  doctest Stevedore

  test "greets the world" do
    assert Stevedore.hello() == :world
  end
end
