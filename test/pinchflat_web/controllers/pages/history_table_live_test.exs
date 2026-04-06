defmodule Pinchflat.Pages.HistoryTableLiveTest do
  use PinchflatWeb.ConnCase

  import Phoenix.LiveViewTest
  import Pinchflat.MediaFixtures
  import Pinchflat.SourcesFixtures

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

end
