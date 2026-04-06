defmodule Pinchflat.Repo.Migrations.FixMediaItemsDownloadedCoveringIndex do
  use Ecto.Migration

  def up do
    # The original index was created with `WHERE media_filepath IS NOT NULL`, but
    # Ecto generates `NOT (media_filepath IS NULL)` for `not is_nil(m.media_filepath)`.
    # SQLite's partial index matching is syntactic, so the planner did not recognise
    # the index as applicable and fell back to full table scans through description
    # blobs (~200s on spinning disk).
    #
    # Recreating the index with the WHERE clause written to match Ecto's output
    # exactly allows SQLite to use it as a covering index-only scan.
    execute "DROP INDEX IF EXISTS idx_media_items_downloaded_agg"

    execute """
    CREATE INDEX idx_media_items_downloaded_agg
    ON media_items(source_id, media_size_bytes)
    WHERE NOT (media_filepath IS NULL)
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS idx_media_items_downloaded_agg"

    execute """
    CREATE INDEX idx_media_items_downloaded_agg
    ON media_items(source_id, media_size_bytes)
    WHERE media_filepath IS NOT NULL
    """
  end
end
