defmodule Pinchflat.Cache.StatsServer do
  @moduledoc """
  GenServer that owns the ETS cache table and keeps it warm.

  Subscribes to PubSub topics and recomputes cached aggregate values when
  the underlying data changes. In the test environment, the ETS table is
  created but no subscriptions or warm-up are performed — tests control
  cache state directly via `Pinchflat.Cache.put/2`.

  Invalidation events are debounced: rapid bursts of PubSub messages (e.g.
  Oban emitting many job:state events at startup) are coalesced into a single
  recompute that runs after a short quiet period.
  """
  use GenServer
  require Logger

  alias Pinchflat.Cache

  # Wait this long after startup before the first warm-up, so that Oban and
  # other processes can finish initializing without contending for DB connections.
  @warm_up_delay_ms 30_000

  # Debounce window for invalidation events. A recompute is scheduled this many
  # milliseconds after the last event; any events arriving in the window reset
  # the timer instead of triggering an immediate recompute.
  @debounce_ms 2_000

  def start_link(opts \\ []) do
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{env: Application.get_env(:pinchflat, :env)}, opts)
  end

  @impl GenServer
  def init(%{env: :test} = state) do
    table = ensure_table()
    {:ok, Map.merge(state, %{table: table, recompute_timer: nil})}
  end

  def init(state) do
    table = ensure_table()
    Phoenix.PubSub.subscribe(Pinchflat.PubSub, "job:state")
    Phoenix.PubSub.subscribe(Pinchflat.PubSub, "media_table")
    Process.send_after(self(), :warm_up, @warm_up_delay_ms)
    {:ok, Map.merge(state, %{table: table, recompute_timer: nil})}
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
    {:noreply, schedule_recompute(state)}
  end

  def handle_info(%{topic: "media_table", event: "reload"}, state) do
    {:noreply, schedule_recompute(state)}
  end

  def handle_info(:warm_up, state) do
    recompute_all()
    {:noreply, state}
  end

  def handle_info(:recompute, state) do
    recompute_all()
    {:noreply, %{state | recompute_timer: nil}}
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

  defp schedule_recompute(%{recompute_timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    new_timer = Process.send_after(self(), :recompute, @debounce_ms)
    %{state | recompute_timer: new_timer}
  end

  defp recompute_all do
    safe_recompute(:recompute_home_stats, &recompute_home_stats/0)
    safe_recompute(:recompute_per_source_counts, &recompute_per_source_counts/0)
    safe_recompute(:recompute_history_counts, &recompute_history_counts/0)
  end

  defp safe_recompute(name, fun) do
    fun.()
  rescue
    e ->
      Logger.warning("StatsServer: #{name} failed: #{Exception.message(e)}")
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

  # Computes all per-source counts in a single pass to avoid running the same
  # expensive GROUP BY queries twice (previously done separately in
  # recompute_source_counts and recompute_media_item_counts).
  defp recompute_per_source_counts do
    alias Pinchflat.Repo
    alias Pinchflat.Media.MediaItem
    alias Pinchflat.Media.MediaQuery
    alias Pinchflat.Sources.Source
    import Ecto.Query

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

  defp recompute_history_counts do
    alias Pinchflat.Repo
    alias Pinchflat.Media.MediaItem
    alias Pinchflat.Media.MediaQuery
    import Ecto.Query

    # pending references source + media_profile bindings, so joins are required.
    pending_count =
      from(m in MediaItem,
        inner_join: s in assoc(m, :source),
        inner_join: mp in assoc(s, :media_profile),
        where: ^MediaQuery.pending()
      )
      |> Repo.aggregate(:count, :id)

    # downloaded only checks media_filepath — no joins needed.
    downloaded_count =
      from(m in MediaItem, where: ^MediaQuery.downloaded())
      |> Repo.aggregate(:count, :id)

    Cache.put(:history_pending_count, pending_count)
    Cache.put(:history_downloaded_count, downloaded_count)
  end
end
