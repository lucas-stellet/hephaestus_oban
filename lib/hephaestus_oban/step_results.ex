defmodule HephaestusOban.StepResults do
  @moduledoc """
  Persistence helpers for `hephaestus_step_results`.

  Step executions and resume events are recorded here before `AdvanceWorker`
  applies them back to the workflow instance. The final `insert/7` argument is
  `workflow_version`, which defaults to `1` in the convenience overloads and is
  persisted with each step result row.
  """

  import Ecto.Query

  alias HephaestusOban.Schema.StepResult

  @doc """
  Inserts a step result with default metadata updates and `workflow_version` `1`.
  """
  def insert(repo, instance_id, step_ref, event, context_updates) do
    insert(repo, instance_id, step_ref, event, context_updates, %{}, 1)
  end

  @doc """
  Inserts a step result with explicit metadata updates and `workflow_version` `1`.
  """
  def insert(repo, instance_id, step_ref, event, context_updates, metadata_updates) do
    insert(repo, instance_id, step_ref, event, context_updates, metadata_updates, 1)
  end

  @doc """
  Inserts a step result row.

  `workflow_version` should match the version stored on the workflow instance so
  later analysis can correlate persisted results with the workflow revision that
  produced them.
  """
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
