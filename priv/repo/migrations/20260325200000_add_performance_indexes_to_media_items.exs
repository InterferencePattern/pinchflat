defmodule Pinchflat.Repo.Migrations.AddPerformanceIndexesToMediaItems do
  use Ecto.Migration

  def change do
    # Composite index for the upgradeable query (MediaQualityUpgradeWorker)
    # which filters on media_filepath IS NOT NULL, prevent_download, and media_redownloaded_at IS NULL
    create(index(:media_items, [:media_filepath, :prevent_download, :media_redownloaded_at]))

    # Index on uploaded_at used by date comparisons in upgradeable, pending, and retention queries
    create(index(:media_items, [:uploaded_at]))

    # Index on culled_at used by retention/culling queries
    create(index(:media_items, [:culled_at]))
  end
end
