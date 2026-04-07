defmodule HephaestusOban.Migration do
  @moduledoc false

  use Ecto.Migration

  def up do
    create table(:hephaestus_step_results, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")

      add :instance_id,
          references(:workflow_instances, type: :uuid, on_delete: :delete_all),
          null: false

      add :step_ref, :string, null: false
      add :event, :string, null: false
      add :context_updates, :map, null: false, default: %{}
      add :processed, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:hephaestus_step_results, [:instance_id],
             where: "NOT processed",
             name: :idx_step_results_pending
           )

    create unique_index(:hephaestus_step_results, [:instance_id, :step_ref],
             where: "NOT processed",
             name: :idx_step_results_unique
           )
  end

  def down do
    drop table(:hephaestus_step_results)
  end
end
