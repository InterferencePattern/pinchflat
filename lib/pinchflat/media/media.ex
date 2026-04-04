defmodule Pinchflat.Media do
  @moduledoc """
  The Media context.
  """

  import Ecto.Query, warn: false
  use Pinchflat.Media.MediaQuery

  alias Pinchflat.Repo
  alias Pinchflat.Tasks
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Utils.FilesystemUtils
  alias Pinchflat.Metadata.MediaMetadata

  alias Pinchflat.Lifecycle.UserScripts.CommandRunner, as: UserScriptRunner

  # Some fields should only be set on insert and not on update.
  @fields_to_drop_on_update [:playlist_index]

  # Fields that affect the stats StatsServer caches (downloaded counts, sizes, pending counts).
  # When any of these change, the affected source's stats need to be refreshed.
  @stats_fields [:media_filepath, :media_size_bytes, :prevent_download, :culled_at]

  @doc """
  Returns the list of media_items.

  Returns [%MediaItem{}, ...].
  """
  def list_media_items do
    Repo.all(MediaItem)
  end

  @doc """
  Returns a list of media_items that are upgradeable based on the redownload delay
  of the media_profile their source belongs to. In this context, upgradeable means
  that it's been long enough since upload that the video may be in a higher quality
  or have better sponsorblock segments (or similar).

  The logic is that a media_item is past_redownload_delay if the media_item's uploaded_at is
  at least redownload_delay_days ago AND `media_downloaded_at` - `redownload_delay_days`
  is before the media_item's `uploaded_at`.

  This logic grabs media that we've recently downloaded AND is recently uploaded, but
  doesn't grab media that we've recently downloaded and was uploaded a long time ago.
  This also makes things work as expected when downloading media from a source for the
  first time.

  Returns [%MediaItem{}, ...]
  """
  def list_upgradeable_media_items do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^MediaQuery.upgradeable())
    |> Repo.all()
  end

  @doc """
  Returns a list of IDs for media_items that are upgradeable. This is a lighter-weight
  version of list_upgradeable_media_items/0 that avoids loading full rows into memory.

  Returns [integer()]
  """
  def list_upgradeable_media_item_ids do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^MediaQuery.upgradeable())
    |> select([mi], mi.id)
    |> Repo.all()
  end

  @doc """
  Returns a MapSet of media_id strings for all media items belonging to
  the given source. Used to efficiently check which videos already exist
  in the database before fetching their full metadata from yt-dlp.

  Returns MapSet.t(String.t())
  """
  def media_ids_for_source(%Source{} = source) do
    MediaQuery.new()
    |> where(^MediaQuery.for_source(source))
    |> select([mi], mi.media_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Returns a list of pending media_items for a given source, where
  pending means the media_item satisfies `MediaQuery.pending`. You
  should really check out that function if you need to know more
  because it has a lot going on.

  Returns [%MediaItem{}, ...].
  """
  def list_pending_media_items_for(%Source{} = source) do
    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic(^MediaQuery.for_source(source) and ^MediaQuery.pending()))
    |> Repo.all()
  end

  @doc """
  For a given media_item, tells you if it is pending download. This is defined as
  the media_item satisfying `MediaQuery.pending` which you should really check out.

  Intentionally does not take the `download_media` setting of the source into account.

  Returns boolean()
  """
  def pending_download?(%MediaItem{} = media_item) do
    media_item = Repo.preload(media_item, source: :media_profile)

    MediaQuery.new()
    |> MediaQuery.require_assoc(:media_profile)
    |> where(^dynamic([m, s, mp], m.id == ^media_item.id and ^MediaQuery.pending()))
    |> Repo.exists?()
  end

  @doc """
  Returns a list of media_items that match the search term. Adds a `matching_search_term`
  virtual field to the result set.

  Has explicit handling for blank search terms because SQLite doesn't like empty MATCH clauses.

  Returns [%MediaItem{}, ...].
  """
  def search(_search_term, _opts \\ [])
  def search("", _opts), do: []
  def search(nil, _opts), do: []

  def search(search_term, opts) do
    limit = Keyword.get(opts, :limit, 50)

    MediaQuery.new()
    |> MediaQuery.matching_search_term(search_term)
    |> Repo.maybe_limit(limit)
    |> Repo.all()
  end

  @doc """
  Gets a single media_item.

  Returns %MediaItem{}. Raises `Ecto.NoResultsError` if the Media item does not exist.
  """
  def get_media_item!(id), do: Repo.get!(MediaItem, id)

  @doc """
  Creates a media_item.

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def create_media_item(attrs) do
    %MediaItem{}
    |> MediaItem.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a media item from the attributes returned by the video backend
  (read: yt-dlp).

  Unlike `create_media_item`, this will attempt an update if the media_item
  already exists. This is so that future indexing can pick up attributes that
  we may not have asked for in the past (eg: uploaded_at)

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def create_media_item_from_backend_attrs(source, media_attrs_struct) do
    attrs = Map.merge(%{source_id: source.id}, Map.from_struct(media_attrs_struct))

    result =
      %MediaItem{}
      |> MediaItem.changeset(attrs)
      |> Repo.insert(
        on_conflict: [
          set:
            attrs
            |> Map.drop(@fields_to_drop_on_update)
            |> Map.to_list()
        ],
        conflict_target: [:source_id, :media_id]
      )

    case result do
      {:ok, media_item} -> broadcast_stats_change(media_item.source_id)
      _ -> :ok
    end

    result
  end

  @doc """
  Updates a media_item.

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def update_media_item(%MediaItem{} = media_item, attrs) do
    update_attrs = Map.drop(attrs, @fields_to_drop_on_update)

    result =
      media_item
      |> MediaItem.changeset(update_attrs)
      |> Repo.update()

    stats_relevant = Enum.any?(@stats_fields, &Map.has_key?(update_attrs, &1))

    case result do
      {:ok, updated} when stats_relevant -> broadcast_stats_change(updated.source_id)
      _ -> :ok
    end

    result
  end

  @doc """
  Deletes a media_item, its associated tasks, and our internal metadata files.
  Can optionally delete the media_item's media files (media, thumbnail, subtitles, etc).

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_media_item(%MediaItem{} = media_item, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    Tasks.delete_tasks_for(media_item)

    if delete_files do
      {:ok, _} = do_delete_media_files(media_item)
      run_user_script(:media_deleted, media_item)
    end

    # Should delete these no matter what
    delete_internal_metadata_files(media_item)
    result = Repo.delete(media_item)

    case result do
      {:ok, _} -> broadcast_stats_change(media_item.source_id)
      _ -> :ok
    end

    result
  end

  @doc """
  Deletes the tasks and media files associated with a media_item but leaves the
  media_item in the database. Does not delete anything to do with associated metadata.

  Optionally accepts a second argument `addl_attrs` which will be merged into the
  media_item before it is updated. Useful for setting things like `prevent_download`
  and `culled_at`, if wanted

  Returns {:ok, %MediaItem{}} | {:error, %Ecto.Changeset{}}
  """
  def delete_media_files(%MediaItem{} = media_item, addl_attrs \\ %{}) do
    filepath_attrs = MediaItem.filepath_attribute_defaults()

    Tasks.delete_tasks_for(media_item)
    {:ok, _} = do_delete_media_files(media_item)
    run_user_script(:media_deleted, media_item)

    update_media_item(media_item, Map.merge(filepath_attrs, addl_attrs))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking media_item changes.
  """
  def change_media_item(%MediaItem{} = media_item, attrs \\ %{}) do
    MediaItem.changeset(media_item, attrs)
  end

  defp do_delete_media_files(media_item) do
    mapped_struct = Map.from_struct(media_item)

    MediaItem.filepath_attributes()
    |> Enum.map(fn
      :subtitle_filepaths = field -> Enum.map(mapped_struct[field], fn [_, filepath] -> filepath end)
      field -> List.wrap(mapped_struct[field])
    end)
    |> List.flatten()
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)

    {:ok, media_item}
  end

  defp delete_internal_metadata_files(media_item) do
    metadata = Repo.preload(media_item, :metadata).metadata || %MediaMetadata{}
    mapped_struct = Map.from_struct(metadata)

    MediaMetadata.filepath_attributes()
    |> Enum.map(fn field -> mapped_struct[field] end)
    |> Enum.filter(&is_binary/1)
    |> Enum.each(&FilesystemUtils.delete_file_and_remove_empty_directories/1)
  end

  defp run_user_script(event, media_item) do
    runner = Application.get_env(:pinchflat, :user_script_runner, UserScriptRunner)

    runner.run(event, media_item)
  end

  defp broadcast_stats_change(source_id) do
    Phoenix.PubSub.broadcast(Pinchflat.PubSub, "stats:source", %{source_id: source_id})
  end
end
