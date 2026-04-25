defmodule Pinchflat.Repo.Migrations.AddMediaItemsCullableIndex do
  use Ecto.Migration

  def up do
    # Supports the MediaRetentionWorker's cullable query. Without this index,
    # the query scanned all media_items on every run (~30k rows, ~20s warm and
    # >90s cold on spinning-disk NAS storage), tripping DBConnection's 90s
    # checkout timeout and crashing the app.
    #
    # Column order is (source_id, media_downloaded_at) so the planner can
    # iterate sources (22 rows) first, compute the retention cutoff per source,
    # then range-seek media_items for that source with
    #   `media_downloaded_at < <per-source cutoff>`.
    #
    # The partial WHERE is written as `NOT (media_filepath IS NULL)` to match
    # Ecto's generated SQL for `not is_nil(mi.media_filepath)` — SQLite matches
    # partial-index predicates syntactically, not semantically. See migration
    # 20260405000001 for prior art on this.
    execute """
    CREATE INDEX media_items_cullable_index
      ON media_items (source_id, media_downloaded_at)
      WHERE NOT (media_filepath IS NULL)
    """

    # Without sqlite_stat1, the planner can't choose between this index and
    # idx_media_items_downloaded_agg (20260405000001), which shares the same
    # `WHERE NOT (media_filepath IS NULL)` predicate but is keyed on
    # (source_id, media_size_bytes) and so can't range-seek by media_downloaded_at.
    # On an unANALYZEd DB it picks the wrong one and the retention SELECT
    # full-scans (~50s on spinning disk) — see 2026-04-24 incident.
    execute "ANALYZE"
  end

  def down do
    execute "DROP INDEX IF EXISTS media_items_cullable_index"
  end
end
