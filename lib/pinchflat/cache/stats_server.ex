defmodule Pinchflat.Cache.StatsServer do
  @moduledoc """
  GenServer that owns the ETS cache table and keeps it warm.

  ## Recompute strategy

  Full recomputes run at boot (after a warm-up delay) and on `media_table:reload`
  events. These run GROUP BY queries across all sources and populate per-source
  count and size caches.

  Incremental updates run when specific media operations occur (download, delete,
  index). The `media.ex` context broadcasts `stats:source` events with the affected
  `source_id`. StatsServer debounces these and recomputes only the changed source
  using point queries (WHERE source_id = X), which are much cheaper than a full
  GROUP BY across all sources.

  In the test environment, the ETS table is created but no subscriptions or warm-up
  are performed — tests control cache state directly via `Pinchflat.Cache.put/2`.
  """
  use GenServer
  require Logger

  import Ecto.Query, warn: false

  alias Pinchflat.Cache
  alias Pinchflat.Repo
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Media.MediaQuery
  alias Pinchflat.Sources.Source

  # Wait this long after startup before the first warm-up, so that Oban and
  # other processes can finish initializing without contending for DB connections.
  @warm_up_delay_ms 30_000

  # Debounce window for per-source invalidation events. A recompute is scheduled
  # this many milliseconds after the last event; any events arriving in the window
  # reset the timer instead of triggering an immediate recompute.
  @debounce_ms 2_000

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{env: Application.get_env(:pinchflat, :env)}, opts)
  end

  @impl GenServer
  def init(%{env: :test} = state) do
    table = ensure_table()
    {:ok, Map.merge(state, %{table: table, dirty_sources: MapSet.new(), dirty_timer: nil})}
  end

  def init(state) do
    table = ensure_table()
    # Per-source incremental updates from media.ex operations
    Phoenix.PubSub.subscribe(Pinchflat.PubSub, "stats:source")
    # Full recompute when the media table LiveView signals a reload
    Phoenix.PubSub.subscribe(Pinchflat.PubSub, "media_table")
    Process.send_after(self(), :warm_up, @warm_up_delay_ms)
    {:ok, Map.merge(state, %{table: table, dirty_sources: MapSet.new(), dirty_timer: nil})}
  end

  defp ensure_table do
    case :ets.info(Cache.table_name()) do
      :undefined ->
        :ets.new(Cache.table_name(), [:named_table, :public, :set, {:read_concurrency, true}])

      _info ->
        Cache.table_name()
    end
  end

  # --- Event handlers ---

  @impl GenServer
  def handle_info(%{topic: "stats:source", payload: %{source_id: source_id}}, state) do
    {:noreply, schedule_source_recompute(state, source_id)}
  end

  def handle_info(%{topic: "media_table", event: "reload"}, state) do
    # Cancel any pending per-source timer and do a full recompute immediately.
    cancel_dirty_timer(state)
    recompute_all()
    {:noreply, %{state | dirty_sources: MapSet.new(), dirty_timer: nil}}
  end

  def handle_info(:warm_up, state) do
    recompute_all()
    {:noreply, state}
  end

  def handle_info(:recompute_dirty, %{dirty_sources: dirty} = state) do
    Enum.each(dirty, &safe_recompute(:recompute_source_stats, fn -> recompute_source_stats(&1) end))
    {:noreply, %{state | dirty_sources: MapSet.new(), dirty_timer: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast(:recompute, state) do
    recompute_all()
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:recompute, _from, state) do
    recompute_all()
    {:reply, :ok, state}
  end

  # --- Private ---

  defp schedule_source_recompute(%{dirty_sources: dirty, dirty_timer: timer} = state, source_id) do
    if timer, do: Process.cancel_timer(timer)
    new_timer = Process.send_after(self(), :recompute_dirty, @debounce_ms)
    %{state | dirty_sources: MapSet.put(dirty, source_id), dirty_timer: new_timer}
  end

  defp cancel_dirty_timer(%{dirty_timer: nil}), do: :ok
  defp cancel_dirty_timer(%{dirty_timer: timer}), do: Process.cancel_timer(timer)

  defp recompute_all do
    safe_recompute(:recompute_per_source_counts, &recompute_per_source_counts/0)
  end

  defp safe_recompute(name, fun) do
    fun.()
  rescue
    e ->
      Logger.warning("StatsServer: #{name} failed: #{Exception.message(e)}")
  end

  # Computes all per-source counts in a single pass to avoid running the same
  # expensive GROUP BY queries twice (previously done separately in
  # recompute_source_counts and recompute_media_item_counts).
  defp recompute_per_source_counts do
    downloaded_data =
      from(m in MediaItem,
        where: ^MediaQuery.downloaded(),
        group_by: m.source_id,
        select: {m.source_id, %{count: count(m.id), size: sum(m.media_size_bytes)}}
      )
      |> Repo.all()
      |> Map.new()

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

    total_counts =
      from(m in MediaItem,
        group_by: m.source_id,
        select: {m.source_id, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    source_ids =
      from(s in Source, where: is_nil(s.marked_for_deletion_at), select: s.id)
      |> Repo.all()

    :ets.match_delete(Cache.table_name(), {{:source_counts, :_}, :_})
    :ets.match_delete(Cache.table_name(), {{:media_item_count, :_, :_}, :_})

    Enum.each(source_ids, fn id ->
      downloaded = Map.get(downloaded_data, id, %{count: 0, size: nil})
      downloaded_count = Map.get(downloaded, :count, 0) || 0
      media_size_bytes = Map.get(downloaded, :size, 0) || 0
      pending = Map.get(pending_counts, id, 0)
      total = Map.get(total_counts, id, 0)
      other = max(total - downloaded_count - pending, 0)

      Cache.put({:source_counts, id}, %{downloaded_count: downloaded_count, pending_count: pending, media_size_bytes: media_size_bytes})
      Cache.put({:media_item_count, id, "downloaded"}, downloaded_count)
      Cache.put({:media_item_count, id, "pending"}, pending)
      Cache.put({:media_item_count, id, "other"}, other)
    end)
  end

  # Recomputes stats for a single source using point queries (WHERE source_id = X).
  # Much cheaper than the full GROUP BY pass — used for incremental updates when
  # a specific source's data changes.
  defp recompute_source_stats(source_id) do
    downloaded =
      from(m in MediaItem,
        where: m.source_id == ^source_id and not is_nil(m.media_filepath),
        select: %{count: count(m.id), size: sum(m.media_size_bytes)}
      )
      |> Repo.one()

    downloaded_count = (downloaded && downloaded.count) || 0
    media_size_bytes = (downloaded && downloaded.size) || 0

    pending_count =
      from(m in MediaItem,
        inner_join: s in assoc(m, :source),
        inner_join: mp in assoc(s, :media_profile),
        where: m.source_id == ^source_id and ^MediaQuery.pending(),
        select: count(m.id)
      )
      |> Repo.one()
      |> Kernel.||(0)

    total_count =
      from(m in MediaItem, where: m.source_id == ^source_id, select: count(m.id))
      |> Repo.one()
      |> Kernel.||(0)

    other = max(total_count - downloaded_count - pending_count, 0)

    Cache.put({:source_counts, source_id}, %{downloaded_count: downloaded_count, pending_count: pending_count, media_size_bytes: media_size_bytes})
    Cache.put({:media_item_count, source_id, "downloaded"}, downloaded_count)
    Cache.put({:media_item_count, source_id, "pending"}, pending_count)
    Cache.put({:media_item_count, source_id, "other"}, other)
  end

end
