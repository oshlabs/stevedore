defmodule Stevedore.Server.Uploads do
  @moduledoc """
  In-progress blob upload sessions for the registry server.

  A registry blob upload is the one inherently stateful part of the `/v2` API: a client opens a
  session, streams chunks (`PATCH`), then finalizes (`PUT`) with the expected digest. This
  `GenServer` holds each session's accumulated bytes keyed by a UUID, and sweeps sessions that
  have been idle longer than `:ttl` (so abandoned uploads don't leak memory).

  Started by `Stevedore.Server`; not part of the weightless core.

  Spec: [distribution-spec, blob uploads](https://github.com/opencontainers/distribution-spec/blob/main/spec.md#pushing-a-blob-in-chunks).
  """

  use GenServer

  @default_ttl :timer.hours(1)
  @sweep_interval :timer.minutes(1)

  @type uuid :: String.t()

  # --- API ---

  @doc "Starts the session store. Options: `:name`, `:ttl` (ms)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Opens a new upload session, returning its UUID."
  @spec create(GenServer.server()) :: {:ok, uuid()}
  def create(server), do: GenServer.call(server, :create)

  @doc """
  Appends `chunk` to a session, returning the new total size.

  `at` is the offset the chunk claims to start at (from a `Content-Range` header). When given, it
  must equal the session's current size or the append is rejected with `{:error, :bad_range}` and
  the session is left untouched — the distribution-spec requires chunks to arrive in order
  (out-of-order or retried chunks yield `416`). Pass `nil` to append unconditionally (streamed
  uploads with no range).
  """
  @spec append(GenServer.server(), uuid(), iodata(), non_neg_integer() | nil) ::
          {:ok, non_neg_integer()} | {:error, :unknown_session | :bad_range}
  def append(server, uuid, chunk, at \\ nil),
    do: GenServer.call(server, {:append, uuid, chunk, at})

  @doc "Current accumulated size of a session."
  @spec size(GenServer.server(), uuid()) :: {:ok, non_neg_integer()} | {:error, :unknown_session}
  def size(server, uuid), do: GenServer.call(server, {:size, uuid})

  @doc "Finalizes a session: removes it and returns the accumulated bytes."
  @spec finish(GenServer.server(), uuid()) :: {:ok, binary()} | {:error, :unknown_session}
  def finish(server, uuid), do: GenServer.call(server, {:finish, uuid})

  @doc "Cancels and discards a session."
  @spec cancel(GenServer.server(), uuid()) :: :ok
  def cancel(server, uuid), do: GenServer.call(server, {:cancel, uuid})

  @doc "Removes sessions idle longer than the TTL. Runs periodically; exposed for tests."
  @spec sweep(GenServer.server()) :: :ok
  def sweep(server), do: GenServer.call(server, :sweep)

  # --- Server ---

  @impl true
  def init(opts) do
    schedule_sweep()
    {:ok, %{sessions: %{}, ttl: Keyword.get(opts, :ttl, @default_ttl)}}
  end

  @impl true
  def handle_call(:create, _from, state) do
    uuid = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    session = %{chunks: [], size: 0, touched_at: now()}
    {:reply, {:ok, uuid}, put_in(state.sessions[uuid], session)}
  end

  def handle_call({:append, uuid, chunk, at}, _from, state) do
    with_session(state, uuid, fn session ->
      if at != nil and at != session.size do
        {{:error, :bad_range}, state}
      else
        size = session.size + IO.iodata_length(chunk)
        session = %{session | chunks: [chunk | session.chunks], size: size, touched_at: now()}
        {{:ok, size}, put_in(state.sessions[uuid], session)}
      end
    end)
  end

  def handle_call({:size, uuid}, _from, state) do
    with_session(state, uuid, fn session -> {{:ok, session.size}, state} end)
  end

  def handle_call({:finish, uuid}, _from, state) do
    with_session(state, uuid, fn session ->
      data = session.chunks |> Enum.reverse() |> IO.iodata_to_binary()
      {{:ok, data}, %{state | sessions: Map.delete(state.sessions, uuid)}}
    end)
  end

  def handle_call({:cancel, uuid}, _from, state) do
    {:reply, :ok, %{state | sessions: Map.delete(state.sessions, uuid)}}
  end

  def handle_call(:sweep, _from, state) do
    {:reply, :ok, expire(state)}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep()
    {:noreply, expire(state)}
  end

  @spec with_session(map(), uuid(), (map() -> {term(), map()})) :: {:reply, term(), map()}
  defp with_session(state, uuid, fun) do
    case state.sessions[uuid] do
      nil ->
        {:reply, {:error, :unknown_session}, state}

      session ->
        {reply, new_state} = fun.(session)
        {:reply, reply, new_state}
    end
  end

  @spec expire(map()) :: map()
  defp expire(state) do
    cutoff = now() - state.ttl
    live = for {uuid, s} <- state.sessions, s.touched_at > cutoff, into: %{}, do: {uuid, s}
    %{state | sessions: live}
  end

  @spec schedule_sweep() :: reference()
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)
end
