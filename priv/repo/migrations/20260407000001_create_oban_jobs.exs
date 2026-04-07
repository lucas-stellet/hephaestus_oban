defmodule HephaestusOban.TestRepo.Migrations.CreateObanJobs do
  use Ecto.Migration

  def change do
    Oban.Migration.up()
  end
end
