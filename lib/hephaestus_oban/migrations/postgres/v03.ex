defmodule HephaestusOban.Migrations.Postgres.V03 do
  @moduledoc false

  use Ecto.Migration

  def up(_opts) do
    alter table(:hephaestus_step_results) do
      add_if_not_exists(:workflow_version, :integer, null: false, default: 1)
    end
  end

  def down(_opts) do
    alter table(:hephaestus_step_results) do
      remove_if_exists(:workflow_version, :integer)
    end
  end
end
