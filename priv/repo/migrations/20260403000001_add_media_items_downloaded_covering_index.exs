defmodule Pinchflat.Repo.Migrations.AddMediaItemsDownloadedCoveringIndex do
  use Ecto.Migration

  def up do
    # Partial covering index for the aggregate queries that StatsServer runs.
    #
    # The three hot queries are:
    #   1. SELECT source_id, count(id), sum(media_size_bytes) ... WHERE media_filepath IS NOT NULL GROUP BY source_id
    #   2. SELECT sum(media_size_bytes) ... WHERE media_filepath IS NOT NULL
    #   3. SELECT count(id) ... WHERE media_filepath IS NOT NULL
    #
    # Without this index, SQLite reads every row's data pages — including large description
    # blobs — just to compute counts and sums. On spinning disk with ~1400 rows this takes
    # 60–200 seconds.
    #
    # With a partial covering index on (source_id, media_size_bytes) filtered to downloaded
    # rows, SQLite can answer all three queries via an index-only scan: it never touches the
    # main table at all. The rowid (serving as `id` for COUNT) is included implicitly in
    # every SQLite index.
    execute """
    CREATE INDEX IF NOT EXISTS idx_media_items_downloaded_agg
    ON media_items(source_id, media_size_bytes)
    WHERE media_filepath IS NOT NULL
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS idx_media_items_downloaded_agg"
  end
end
