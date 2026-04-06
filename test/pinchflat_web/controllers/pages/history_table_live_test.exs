defmodule Pinchflat.Pages.HistoryTableLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

  alias Pinchflat.Cache
  alias Pinchflat.Pages.HistoryTableLive

  describe "initial rendering" do
    test "shows message when no records", %{conn: conn} do
      {:ok, _view, html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "downloaded"})

      assert html =~ "Nothing Here!"
      refute html =~ "Showing"
    end

    test "shows downloaded records when present", %{conn: conn} do
      source = source_fixture()
      media_item = media_item_fixture(source_id: source.id)

      {:ok, _view, html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "downloaded"})

      assert html =~ "Showing"
      assert html =~ media_item.title
    end
  end

  describe "count caching" do
    test "uses cached count for total_record_count display when cache is populated", %{conn: conn} do
      source = source_fixture()
      _media_item = media_item_fixture(source_id: source.id)

      # Pre-populate the cache with a known value
      Cache.put(:history_downloaded_count, 99)

      {:ok, _view, html} = live_isolated(conn, HistoryTableLive, session: %{"media_state" => "downloaded"})

      # The rendered count should reflect the cached value, not the real DB count
      assert html =~ "99"

      Cache.delete(:history_downloaded_count)
    end
  end
end
