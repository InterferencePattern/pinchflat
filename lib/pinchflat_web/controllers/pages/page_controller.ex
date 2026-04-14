defmodule PinchflatWeb.Pages.PageController do
  use PinchflatWeb, :controller

  alias Pinchflat.Repo
  alias Pinchflat.Sources.Source
  alias Pinchflat.Profiles.MediaProfile
  alias Pinchflat.Media.MediaItem

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
    import Ecto.Query, warn: false

    downloaded = from(m in MediaItem, where: not is_nil(m.media_filepath))

    conn
    |> render(:home,
      media_profile_count: Repo.aggregate(MediaProfile, :count, :id),
      source_count: Repo.aggregate(Source, :count, :id),
      media_item_size: Repo.aggregate(downloaded, :sum, :media_size_bytes),
      media_item_count: Repo.aggregate(downloaded, :count, :id)
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
