defmodule HephaestusOban.Migrations.Postgres.V02 do
  @moduledoc false

  use Ecto.Migration

  def up(%{prefix: prefix}) do
    alter table(:hephaestus_step_results, prefix: prefix) do
      add_if_not_exists(:metadata_updates, :map, null: false, default: %{})
    end
  end

  def down(%{prefix: prefix}) do
    alter table(:hephaestus_step_results, prefix: prefix) do
      remove_if_exists(:metadata_updates, :map)
    end
  end
end
