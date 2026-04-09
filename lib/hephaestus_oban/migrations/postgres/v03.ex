defmodule HephaestusOban.Migrations.Postgres.V03 do
  @moduledoc false

  use Ecto.Migration

  def up(%{prefix: prefix}) do
    alter table(:hephaestus_step_results, prefix: prefix) do
      add_if_not_exists(:workflow_version, :integer, null: false, default: 1)
    end
  end

  def down(%{prefix: prefix}) do
    alter table(:hephaestus_step_results, prefix: prefix) do
      remove_if_exists(:workflow_version, :integer)
    end
  end
end
