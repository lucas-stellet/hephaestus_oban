defmodule HephaestusOban.Migrations.Postgres.V02 do
  @moduledoc false

  use Ecto.Migration

  def up(_opts) do
    alter table(:hephaestus_step_results) do
      add_if_not_exists(:metadata_updates, :map, null: false, default: %{})
    end
  end

  def down(_opts) do
    alter table(:hephaestus_step_results) do
      remove_if_exists(:metadata_updates, :map)
    end
  end
end
