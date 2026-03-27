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

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{env: Application.get_env(:pinchflat, :env)}, opts)
  end

  @impl GenServer
  def init(%{env: :test} = state) do
    table = ensure_table()
    {:ok, Map.put(state, :table, table)}
  end

  def init(state) do
    table = ensure_table()
    PinchflatWeb.Endpoint.subscribe("job:state")
    PinchflatWeb.Endpoint.subscribe("media_table")
    Process.send(self(), :warm_up, [])
    {:ok, Map.put(state, :table, table)}
  end

  defp ensure_table do
    case :ets.info(Cache.table_name()) do
      :undefined ->
        :ets.new(Cache.table_name(), [:named_table, :public, :set, {:read_concurrency, true}])

      _info ->
        Cache.table_name()
    end
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

  @impl GenServer
  def handle_call(:recompute, _from, state) do
    recompute_all()
    {:reply, :ok, state}
  end

  # --- Private ---

  defp recompute_all do
    recompute_home_stats()
    recompute_source_counts()
    recompute_history_counts()
  end

  defp recompute_home_stats do
    alias Pinchflat.Repo
    alias Pinchflat.Media.MediaItem
    alias Pinchflat.Sources.Source
    alias Pinchflat.Profiles.MediaProfile
    import Ecto.Query

    downloaded = from(m in MediaItem, where: not is_nil(m.media_filepath))

    value = %{
      media_profile_count: Repo.aggregate(MediaProfile, :count, :id),
      source_count: Repo.aggregate(Source, :count, :id),
      media_item_size: Repo.aggregate(downloaded, :sum, :media_size_bytes),
      media_item_count: Repo.aggregate(downloaded, :count, :id)
    }

    Cache.put(:home_stats, value)
  end

  # Stubs — will be implemented in later phases
  defp recompute_source_counts, do: :ok
  defp recompute_history_counts, do: :ok
end
