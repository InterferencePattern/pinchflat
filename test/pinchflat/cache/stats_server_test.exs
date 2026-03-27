defmodule Pinchflat.Cache.StatsServerTest do
  use Pinchflat.DataCase, async: false

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
  end
end
