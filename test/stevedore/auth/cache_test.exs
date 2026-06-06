defmodule Stevedore.Auth.CacheTest do
  use ExUnit.Case, async: true

  alias Stevedore.Auth.Cache

  @key {"registry.test", "repository:library/alpine:pull"}

  test "get on an empty cache misses" do
    cache = start_supervised!(Cache)
    assert :miss = Cache.get(cache, @key)
  end

  test "put then get returns the token" do
    cache = start_supervised!(Cache)
    assert :ok = Cache.put(cache, @key, "TKN")
    assert {:ok, "TKN"} = Cache.get(cache, @key)
  end

  test "an expired entry misses (ttl 0)" do
    cache = start_supervised!(Cache)
    assert :ok = Cache.put(cache, @key, "TKN", 0)
    assert :miss = Cache.get(cache, @key)
  end

  test "the configured :ttl is the default for puts" do
    cache = start_supervised!({Cache, ttl: 0})
    # No per-put ttl, so the cache's :ttl (0) applies — immediately expired.
    assert :ok = Cache.put(cache, @key, "TKN")
    assert :miss = Cache.get(cache, @key)
  end

  test "a later put overwrites and refreshes a stale entry" do
    cache = start_supervised!(Cache)
    Cache.put(cache, @key, "OLD", 0)
    Cache.put(cache, @key, "NEW")
    assert {:ok, "NEW"} = Cache.get(cache, @key)
  end

  test "clear drops everything" do
    cache = start_supervised!(Cache)
    Cache.put(cache, @key, "TKN")
    assert :ok = Cache.clear(cache)
    assert :miss = Cache.get(cache, @key)
  end

  test "entries are keyed independently by {registry, scope}" do
    cache = start_supervised!(Cache)
    Cache.put(cache, {"a.test", "s"}, "TA")
    Cache.put(cache, {"b.test", "s"}, "TB")
    assert {:ok, "TA"} = Cache.get(cache, {"a.test", "s"})
    assert {:ok, "TB"} = Cache.get(cache, {"b.test", "s"})
    assert :miss = Cache.get(cache, {"c.test", "s"})
  end
end
