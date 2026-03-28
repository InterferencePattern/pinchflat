defmodule PinchflatWeb.Pages.PageController do
  use PinchflatWeb, :controller

  alias Pinchflat.Cache
  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile

  def home(conn, params) do
    done_onboarding = params["onboarding"] == "0"
    force_onboarding = params["onboarding"] == "1"

    if done_onboarding, do: Settings.set(onboarding: false)

    if force_onboarding || Settings.get!(:onboarding) do
      render_onboarding_page(conn)
    else
      render_home_page(conn)
    end
  end

  defp render_home_page(conn) do
    stats =
      Cache.get(:home_stats, %{
        media_profile_count: 0,
        source_count: 0,
        media_item_size: nil,
        media_item_count: 0
      })

    conn
    |> render(:home,
      media_profile_count: stats.media_profile_count,
      source_count: stats.source_count,
      media_item_size: stats.media_item_size,
      media_item_count: stats.media_item_count
    )
  end

  defp render_onboarding_page(conn) do
    Settings.set(onboarding: true)

    conn
    |> render(:onboarding_checklist,
      media_profiles_exist: Repo.exists?(MediaProfile),
      sources_exist: Repo.exists?(Source),
      layout: {Layouts, :onboarding}
    )
  end
end
