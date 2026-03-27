defmodule Pinchflat.Cache do
  @moduledoc """
  Thin wrapper around an ETS table used to cache expensive aggregate queries.

  Reads are served directly from ETS (no GenServer round-trip). Writes are
  performed exclusively by `Pinchflat.Cache.StatsServer`, which subscribes
  to PubSub events and recomputes cached values when underlying data changes.

  All public functions accept a fallback_fn that is called transparently when
  the cache is cold (e.g. immediately after startup before warm-up completes).
  """

  @table :pinchflat_cache

  def table_name, do: @table

  def get(key, fallback_fn) when is_function(fallback_fn, 0) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> fallback_fn.()
    end
  end

  def put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  end

  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end
end
