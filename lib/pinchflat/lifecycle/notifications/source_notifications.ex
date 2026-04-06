defmodule Pinchflat.Lifecycle.Notifications.SourceNotifications do
  @moduledoc """
  Contains utilities for sending notifications about sources
  """

  require Logger

  @doc """
  Sends a notification if the count of new media items has changed.

  The caller is responsible for determining the count of new items
  (e.g. by counting successful creates from the indexing return value)
  rather than querying the database for before/after counts.

  Returns :ok
  """
  def send_new_media_notification(_, _, count) when count <= 0, do: :ok

  def send_new_media_notification(servers, source, changed_count) do
    opts = [
      title: "[Pinchflat] New media found",
      body: "Found #{changed_count} new media item(s) for #{source.custom_name}. Downloading them now"
    ]

    case backend_runner().run(servers, opts) do
      {:ok, _} ->
        Logger.info("Sent new media notification for source #{source.id}")

      {:error, :no_servers} ->
        Logger.info("No notification servers provided for source #{source.id}")

      {:error, err} ->
        Logger.error("Failed to send new media notification for source #{source.id}: #{err}")
    end

    :ok
  end

  defp backend_runner do
    # This approach lets us mock the command for testing
    Application.get_env(:pinchflat, :apprise_runner)
  end
end
