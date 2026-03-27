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
    recompute_media_item_counts()
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

  defp recompute_source_counts do
    alias Pinchflat.Repo
    alias Pinchflat.Media.MediaItem
    alias Pinchflat.Media.MediaQuery
    alias Pinchflat.Sources.Source
    import Ecto.Query

    # Fetch counts for downloaded items per source using a single GROUP BY query
    downloaded_counts =
      from(m in MediaItem,
        where: ^MediaQuery.downloaded(),
        group_by: m.source_id,
        select: {m.source_id, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Fetch counts for pending items per source using a single GROUP BY query.
    # Pending conditions reference source and media_profile bindings, so we join them.
    pending_counts =
      from(m in MediaItem,
        inner_join: s in assoc(m, :source),
        inner_join: mp in assoc(s, :media_profile),
        where: ^MediaQuery.pending(),
        group_by: m.source_id,
        select: {m.source_id, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Fetch all non-deleted source IDs
    source_ids =
      from(s in Source, where: is_nil(s.marked_for_deletion_at), select: s.id)
      |> Repo.all()

    # Clean up stale entries for deleted sources
    :ets.match_delete(Cache.table_name(), {{:source_counts, :_}, :_})

    # Write a cache entry per source
    Enum.each(source_ids, fn id ->
      counts = %{
        downloaded_count: Map.get(downloaded_counts, id, 0),
        pending_count: Map.get(pending_counts, id, 0)
      }

      Cache.put({:source_counts, id}, counts)
    end)
  end

  defp recompute_media_item_counts do
    alias Pinchflat.Repo
    alias Pinchflat.Media.MediaItem
    alias Pinchflat.Media.MediaQuery
    alias Pinchflat.Sources.Source
    import Ecto.Query

    # Fetch counts for downloaded items per source using a single GROUP BY query
    downloaded_counts =
      from(m in MediaItem,
        where: ^MediaQuery.downloaded(),
        group_by: m.source_id,
        select: {m.source_id, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Fetch counts for pending items per source using a single GROUP BY query
    pending_counts =
      from(m in MediaItem,
        inner_join: s in assoc(m, :source),
        inner_join: mp in assoc(s, :media_profile),
        where: ^MediaQuery.pending(),
        group_by: m.source_id,
        select: {m.source_id, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Fetch total counts per source (all media items regardless of state)
    total_counts =
      from(m in MediaItem,
        group_by: m.source_id,
        select: {m.source_id, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Fetch all non-deleted source IDs
    source_ids =
      from(s in Source, where: is_nil(s.marked_for_deletion_at), select: s.id)
      |> Repo.all()

    # Clean up stale entries
    :ets.match_delete(Cache.table_name(), {{:media_item_count, :_, :_}, :_})

    # Write a cache entry per source per state
    Enum.each(source_ids, fn id ->
      downloaded = Map.get(downloaded_counts, id, 0)
      pending = Map.get(pending_counts, id, 0)
      total = Map.get(total_counts, id, 0)
      other = max(total - downloaded - pending, 0)

      Cache.put({:media_item_count, id, "downloaded"}, downloaded)
      Cache.put({:media_item_count, id, "pending"}, pending)
      Cache.put({:media_item_count, id, "other"}, other)
    end)
  end

  defp recompute_history_counts, do: :ok
end
