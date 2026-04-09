defmodule HephaestusOban.Migrations.Postgres.V01 do
  @moduledoc false

  use Ecto.Migration

  def up(%{prefix: prefix}) do
    create_if_not_exists table(:hephaestus_step_results, primary_key: false, prefix: prefix) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :instance_id,
        references(:workflow_instances, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:step_ref, :string, null: false)
      add(:event, :string, null: false)
      add(:context_updates, :map, null: false, default: %{})
      add(:processed, :boolean, null: false, default: false)
      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create_if_not_exists(
      index(:hephaestus_step_results, [:instance_id],
        where: "NOT processed",
        name: :idx_step_results_pending,
        prefix: prefix
      )
    )

    create_if_not_exists(
      unique_index(:hephaestus_step_results, [:instance_id, :step_ref],
        where: "NOT processed",
        name: :idx_step_results_unique,
        prefix: prefix
      )
    )
  end

  def down(%{prefix: prefix}) do
    drop_if_exists(table(:hephaestus_step_results, prefix: prefix))
  end
end
