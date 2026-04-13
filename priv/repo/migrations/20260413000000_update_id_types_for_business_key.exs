defmodule HephaestusOban.TestRepo.Migrations.UpdateIdTypesForBusinessKey do
  use Ecto.Migration

  def up do
    HephaestusEcto.Migration.up()
    HephaestusOban.Migration.up()
  end

  def down do
    HephaestusOban.Migration.down()
    HephaestusEcto.Migration.down()
  end
end
