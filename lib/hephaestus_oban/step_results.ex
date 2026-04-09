defmodule HephaestusOban.StepResults do
  @moduledoc false

  import Ecto.Query

  alias HephaestusOban.Schema.StepResult

  def insert(repo, instance_id, step_ref, event, context_updates) do
    insert(repo, instance_id, step_ref, event, context_updates, %{}, 1)
  end

  def insert(repo, instance_id, step_ref, event, context_updates, metadata_updates) do
    insert(repo, instance_id, step_ref, event, context_updates, metadata_updates, 1)
  end

  def insert(
        repo,
        instance_id,
        step_ref,
        event,
        context_updates,
        metadata_updates,
        workflow_version
      ) do
    attrs = %{
      instance_id: instance_id,
      step_ref: step_ref,
      event: event,
      workflow_version: workflow_version,
      context_updates: context_updates,
      metadata_updates: metadata_updates
    }

    %StepResult{}
    |> StepResult.changeset(attrs)
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, ~s|(instance_id, step_ref) WHERE NOT processed|}
    )
    |> case do
      {:ok, _result} ->
        :ok

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  def exists?(repo, instance_id, step_ref) do
    repo.exists?(
      from(step_result in StepResult,
        where:
          step_result.instance_id == ^instance_id and
            step_result.step_ref == ^step_ref and
            not step_result.processed
      )
    )
  end

  def pending_for(repo, instance_id) do
    repo.all(
      from(step_result in StepResult,
        where: step_result.instance_id == ^instance_id and not step_result.processed,
        order_by: [asc: step_result.inserted_at]
      )
    )
  end

  def mark_processed(_repo, []), do: :ok

  def mark_processed(repo, results) do
    ids = Enum.map(results, & &1.id)

    from(step_result in StepResult, where: step_result.id in ^ids)
    |> repo.update_all(set: [processed: true])

    :ok
  end
end
