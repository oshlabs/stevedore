defmodule Stevedore.Auth.Cache do
  @moduledoc """
  An opt-in, in-process cache of registry bearer tokens, keyed by `{registry, scope}`.

  By default `Stevedore.Registry` re-runs the `401 → token` handshake on every request. Start a
  cache and pass it as the `:token_cache` option to reuse a token across the manifest + blob
  fetches of a pull: the first request earns the token, the rest send it **preemptively** —
  skipping both the `401` and the token-endpoint round-trip. A stale or rejected token still
  falls back to a fresh handshake, so the cache never changes results, only request count.

  Tokens are cached for `:ttl` milliseconds (default 60s, comfortably inside a typical registry
  token lifetime); the `401` fallback covers any token that expires sooner. Starting a cache is
  the consumer's choice — nothing here runs unless you start it, preserving Stevedore's
  weightless-by-default invariant.

  ## Example

      {:ok, cache} = Stevedore.Auth.Cache.start_link([])
      Stevedore.copy("docker://alpine:3.20", "oci:./alpine:3.20", token_cache: cache)
  """

  use Agent

  @default_ttl 60_000

  @typedoc "A cache entry's key: the registry host and the auth scope the token is valid for."
  @type key :: {registry :: String.t(), scope :: String.t()}

  @doc """
  Starts a token cache.

  Options: `:name` (register the process under a name) and `:ttl` (token lifetime in
  milliseconds, default `#{@default_ttl}`). Other options are passed to `Agent.start_link/2`.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    {ttl, agent_opts} = Keyword.pop(opts, :ttl, @default_ttl)
    Agent.start_link(fn -> %{ttl: ttl, entries: %{}} end, agent_opts)
  end

  @doc "Returns `{:ok, token}` for `key`, or `:miss` when it is absent or expired."
  @spec get(Agent.agent(), key()) :: {:ok, String.t()} | :miss
  def get(server, key) do
    Agent.get(server, fn %{entries: entries} ->
      case Map.get(entries, key) do
        {token, expires_at} when is_binary(token) ->
          if monotonic_ms() < expires_at, do: {:ok, token}, else: :miss

        _ ->
          :miss
      end
    end)
  end

  @doc """
  Caches `token` under `key`.

  `ttl` is the lifetime in milliseconds, or `:default` to use the cache's configured `:ttl`.
  """
  @spec put(Agent.agent(), key(), String.t(), non_neg_integer() | :default) :: :ok
  def put(server, key, token, ttl \\ :default) when is_binary(token) do
    Agent.update(server, fn %{ttl: default_ttl, entries: entries} = state ->
      ms = if ttl == :default, do: default_ttl, else: ttl
      %{state | entries: Map.put(entries, key, {token, monotonic_ms() + ms})}
    end)
  end

  @doc "Drops all cached tokens."
  @spec clear(Agent.agent()) :: :ok
  def clear(server), do: Agent.update(server, &%{&1 | entries: %{}})

  # Monotonic time can't jump backward, so TTL comparisons are immune to wall-clock changes.
  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
