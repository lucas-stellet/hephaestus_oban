defmodule HephaestusOban.TestRepo.Migrations.AddMetadataUpdates do
  use Ecto.Migration

  def change do
    HephaestusOban.Migration.add_metadata_updates()
  end
end
