defmodule HephaestusOban.Schema.StepResult do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "hephaestus_step_results" do
    field :instance_id, :binary_id
    field :step_ref, :string
    field :event, :string
    field :context_updates, :map, default: %{}
    field :processed, :boolean, default: false
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(step_result, attrs) do
    step_result
    |> cast(attrs, [:instance_id, :step_ref, :event, :context_updates])
    |> validate_required([:instance_id, :step_ref, :event])
  end
end
