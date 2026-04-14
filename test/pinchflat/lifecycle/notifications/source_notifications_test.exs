defmodule Pinchflat.Lifecycle.Notifications.SourceNotificationsTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures

  alias Pinchflat.Lifecycle.Notifications.SourceNotifications

  @apprise_servers ["server_1", "server_2"]

  describe "send_new_media_notification/3" do
    test "sends a notification when count is positive" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, fn servers, opts ->
        assert servers == @apprise_servers

        assert opts == [
                 title: "[Pinchflat] New media found",
                 body: "Found 1 new media item(s) for #{source.custom_name}. Downloading them now"
               ]

        {:ok, ""}
      end)

      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 1)
    end

    test "does not send a notification when count not positive" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, 0, fn _, _ -> {:ok, ""} end)

      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 0)
      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, -1)
    end

    test "sends correct count for multiple items" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, fn _servers, opts ->
        assert opts[:body] =~ "Found 5 new media item(s)"
        {:ok, ""}
      end)

      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 5)
    end

    test "handles runner errors gracefully" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, fn _servers, _opts ->
        {:error, "connection refused"}
      end)

      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 1)
    end

    test "handles no servers gracefully" do
      source = source_fixture()

      expect(AppriseRunnerMock, :run, fn _servers, _opts ->
        {:error, :no_servers}
      end)

      :ok = SourceNotifications.send_new_media_notification(@apprise_servers, source, 1)
    end
  end
end
