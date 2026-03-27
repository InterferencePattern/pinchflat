defmodule Pinchflat.Cache.StatsServer do
  @moduledoc """
  GenServer that owns the ETS cache table and keeps it warm.

  Subscribes to PubSub topics and recomputes cached aggregate values when
  the underlying data changes. In the test environment, the ETS table is
  created but no subscriptions or warm-up are performed — tests control
  cache state directly via `Pinchflat.Cache.put/2`.
  """
  use GenServer
  require Logger

  alias Pinchflat.Cache

  @pubsub Pinchflat.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{env: Application.get_env(:pinchflat, :env)}, opts)
  end

  @impl GenServer
  def init(%{env: :test} = state) do
    table = :ets.new(Cache.table_name(), [:named_table, :public, :set, {:read_concurrency, true}])
    {:ok, Map.put(state, :table, table)}
  end

  def init(state) do
    table = :ets.new(Cache.table_name(), [:named_table, :public, :set, {:read_concurrency, true}])
    PinchflatWeb.Endpoint.subscribe("job:state")
    PinchflatWeb.Endpoint.subscribe("media_table")
    Process.send(self(), :warm_up, [])
    {:ok, Map.put(state, :table, table)}
  end

  @impl GenServer
  def handle_info(%{topic: "job:state", event: "change"}, state) do
    recompute_all()
    {:noreply, state}
  end

  def handle_info(%{topic: "media_table", event: "reload"}, state) do
    recompute_all()
    {:noreply, state}
  end

  def handle_info(:warm_up, state) do
    recompute_all()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp recompute_all do
    recompute_home_stats()
    recompute_source_counts()
    recompute_history_counts()
  end

  # Stubs — will be implemented in later phases
  defp recompute_home_stats, do: :ok
  defp recompute_source_counts, do: :ok
  defp recompute_history_counts, do: :ok
end
