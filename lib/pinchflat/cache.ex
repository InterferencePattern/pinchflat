defmodule Pinchflat.Cache do
  @moduledoc """
  Thin wrapper around an ETS table used to cache expensive aggregate queries.

  Reads are served directly from ETS (no GenServer round-trip). Writes are
  performed exclusively by `Pinchflat.Cache.StatsServer`, which subscribes
  to PubSub events and recomputes cached values when underlying data changes.

  When the cache is cold (before StatsServer warm-up completes), `get/2`
  returns the provided default. The default can be a static value or a
  zero-arity function that is called lazily on cache miss. Use static
  defaults on pages that load at startup (home page) to avoid competing
  with warm-up for DB connections.
  """

  @table :pinchflat_cache

  def table_name, do: @table

  def get(key, default_or_fn \\ nil) do
    if :ets.whereis(@table) == :undefined do
      if is_function(default_or_fn, 0), do: default_or_fn.(), else: default_or_fn
    else
      case :ets.lookup(@table, key) do
        [{^key, value}] -> value
        [] -> if is_function(default_or_fn, 0), do: default_or_fn.(), else: default_or_fn
      end
    end
  end

  def put(key, value) do
    if :ets.whereis(@table) != :undefined, do: :ets.insert(@table, {key, value})
    :ok
  end

  def delete(key) do
    if :ets.whereis(@table) != :undefined, do: :ets.delete(@table, key)
    :ok
  end
end
