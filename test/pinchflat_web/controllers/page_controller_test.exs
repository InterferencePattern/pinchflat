defmodule PinchflatWeb.PageControllerTest do
  use PinchflatWeb.ConnCase

  alias Pinchflat.Cache
  alias Pinchflat.Settings

  describe "GET / home page stats caching" do
    setup do
      Settings.set(onboarding: false)
      Cache.delete(:home_stats)
      :ok
    end

    test "renders successfully when :home_stats is populated in the cache", %{conn: conn} do
      Cache.put(:home_stats, %{
        media_profile_count: 3,
        source_count: 5,
        media_item_size: 1_000_000,
        media_item_count: 42
      })

      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "MENU"
    end

    test "renders successfully when :home_stats is NOT in the cache (fallback path)", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "MENU"
    end
  end

  describe "GET / when testing onboarding" do
    test "sets the onboarding setting to true when onboarding", %{conn: conn} do
      _conn = get(conn, ~p"/")
      assert Settings.get!(:onboarding)
    end

    test "displays the onboarding page when onboarding is forced", %{conn: conn} do
      Settings.set(onboarding: false)

      conn = get(conn, ~p"/?onboarding=1")
      assert html_response(conn, 200) =~ "Welcome to Pinchflat"
    end

    test "sets the onboarding setting to false if you pass the corrent query param", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert Settings.get!(:onboarding)

      _conn = get(conn, ~p"/?onboarding=0")
      refute Settings.get!(:onboarding)
    end

    test "displays the home page when not onboarding", %{conn: conn} do
      Settings.set(onboarding: false)

      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "MENU"
    end
  end
end
