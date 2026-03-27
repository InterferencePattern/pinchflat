defmodule Pinchflat.Cache.StatsServerTest do
  use Pinchflat.DataCase, async: false

  import Pinchflat.SourcesFixtures
  import Pinchflat.MediaFixtures

  alias Pinchflat.Cache
  alias Pinchflat.Cache.StatsServer

  setup do
    # The ETS table and StatsServer are already started by the app supervision tree.
    # Clean up :home_stats before each test to ensure a clean state.
    Cache.delete(:home_stats)
    :ok
  end

  # Returns the PID of the already-running StatsServer from the supervision tree.
  defp server_pid, do: Process.whereis(StatsServer)

  describe "ETS table" do
    test "the ETS table exists and is accessible" do
      assert :ets.info(Cache.table_name()) != :undefined
      assert Cache.put(:stats_server_test_probe, :alive) == :ok
      assert Cache.get(:stats_server_test_probe, fn -> :missing end) == :alive
      Cache.delete(:stats_server_test_probe)
    end
  end

  describe "handle_info/2 — PubSub and internal messages" do
    test "handles job:state change message without crashing" do
      pid = server_pid()
      assert is_pid(pid)
      send(pid, %{topic: "job:state", event: "change"})
      # Synchronise — :sys.get_state/1 waits for the GenServer to process all pending messages
      :sys.get_state(pid)
      assert Process.alive?(pid)
    end

    test "handles media_table reload message without crashing" do
      pid = server_pid()
      assert is_pid(pid)
      send(pid, %{topic: "media_table", event: "reload"})
      :sys.get_state(pid)
      assert Process.alive?(pid)
    end

    test "handles :warm_up message without crashing" do
      pid = server_pid()
      assert is_pid(pid)
      send(pid, :warm_up)
      :sys.get_state(pid)
      assert Process.alive?(pid)
    end

    test "handles unknown messages without crashing" do
      pid = server_pid()
      assert is_pid(pid)
      send(pid, :completely_unknown_message)
      :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end

  describe "recompute_all via handle_call(:recompute)" do
    test "populates :home_stats in the cache with the expected keys" do
      assert Cache.get(:home_stats, fn -> nil end) == nil

      :ok = GenServer.call(server_pid(), :recompute)

      stats = Cache.get(:home_stats, fn -> nil end)
      assert is_map(stats)
      assert Map.has_key?(stats, :media_profile_count)
      assert Map.has_key?(stats, :source_count)
      assert Map.has_key?(stats, :media_item_size)
      assert Map.has_key?(stats, :media_item_count)
    end

    test "populates {:source_counts, source_id} for each non-deleted source" do
      source = source_fixture()

      # Ensure no stale entry exists before recompute
      Cache.delete({:source_counts, source.id})

      :ok = GenServer.call(server_pid(), :recompute)

      counts = Cache.get({:source_counts, source.id}, fn -> nil end)
      assert is_map(counts)
      assert Map.has_key?(counts, :downloaded_count)
      assert Map.has_key?(counts, :pending_count)
      assert is_integer(counts.downloaded_count)
      assert is_integer(counts.pending_count)
    end

    test "source_counts reflects actual downloaded and pending media" do
      source = source_fixture()

      # Create one downloaded media item (media_filepath is set by default in media_item_fixture)
      _downloaded = media_item_fixture(source_id: source.id)

      :ok = GenServer.call(server_pid(), :recompute)

      counts = Cache.get({:source_counts, source.id}, fn -> nil end)
      assert counts.downloaded_count == 1
      assert counts.pending_count == 0
    end

    test "does not create a cache entry for deleted sources" do
      deleted_source = source_fixture(marked_for_deletion_at: DateTime.utc_now())

      :ok = GenServer.call(server_pid(), :recompute)

      result = Cache.get({:source_counts, deleted_source.id}, fn -> :missing end)
      assert result == :missing
    end

    test "populates {:media_item_count, source_id, 'downloaded'} with an integer" do
      source = source_fixture()
      _downloaded = media_item_fixture(source_id: source.id)

      Cache.delete({:media_item_count, source.id, "downloaded"})

      :ok = GenServer.call(server_pid(), :recompute)

      result = Cache.get({:media_item_count, source.id, "downloaded"}, fn -> nil end)
      assert is_integer(result)
      assert result == 1
    end

    test "populates {:media_item_count, source_id, 'pending'} with an integer" do
      source = source_fixture()

      Cache.delete({:media_item_count, source.id, "pending"})

      :ok = GenServer.call(server_pid(), :recompute)

      result = Cache.get({:media_item_count, source.id, "pending"}, fn -> nil end)
      assert is_integer(result)
    end
  end
end
