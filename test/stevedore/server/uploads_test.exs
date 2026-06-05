defmodule Stevedore.Server.UploadsTest do
  use ExUnit.Case, async: true

  alias Stevedore.Server.Uploads

  defp start(opts \\ []) do
    name = :"uploads_#{System.unique_integer([:positive])}"
    start_supervised!({Uploads, Keyword.put(opts, :name, name)})
  end

  test "accumulates chunks and finalizes to the concatenated bytes" do
    up = start()
    {:ok, uuid} = Uploads.create(up)

    assert {:ok, 5} = Uploads.append(up, uuid, "hello")
    assert {:ok, 11} = Uploads.append(up, uuid, " world")
    assert {:ok, 11} = Uploads.size(up, uuid)
    assert {:ok, "hello world"} = Uploads.finish(up, uuid)

    # Finishing removes the session.
    assert {:error, :unknown_session} = Uploads.size(up, uuid)
  end

  test "operations on an unknown session report :unknown_session" do
    up = start()
    assert {:error, :unknown_session} = Uploads.append(up, "nope", "x")
    assert {:error, :unknown_session} = Uploads.size(up, "nope")
    assert {:error, :unknown_session} = Uploads.finish(up, "nope")
  end

  test "cancel discards a session" do
    up = start()
    {:ok, uuid} = Uploads.create(up)
    assert :ok = Uploads.cancel(up, uuid)
    assert {:error, :unknown_session} = Uploads.size(up, uuid)
  end

  test "sweep garbage-collects idle sessions past the TTL" do
    up = start(ttl: 0)
    {:ok, uuid} = Uploads.create(up)
    assert {:ok, 0} = Uploads.size(up, uuid)

    assert :ok = Uploads.sweep(up)
    assert {:error, :unknown_session} = Uploads.size(up, uuid)
  end

  test "sweep keeps fresh sessions" do
    up = start(ttl: :timer.hours(1))
    {:ok, uuid} = Uploads.create(up)
    assert :ok = Uploads.sweep(up)
    assert {:ok, 0} = Uploads.size(up, uuid)
  end
end
