defmodule HephaestusOban.ExecuteStepWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :hephaestus,
    unique: [
      keys: [:instance_id, :step_ref],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias Hephaestus.Core.Engine
  alias HephaestusOban.{JobMetadata, StepResults}

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{
            "instance_id" => instance_id,
            "step_ref" => step_ref,
            "workflow" => workflow_string
          }
        } = job
      ) do
    config = resolve_config(job)

    if StepResults.exists?(config.repo, instance_id, step_ref) do
      {:ok, :already_recorded}
    else
      instance = load_instance(config, instance_id)
      step_module = String.to_existing_atom(step_ref)

      case Engine.execute_step(instance, step_module) do
        {:ok, event} ->
          insert_result_and_advance(
            config,
            instance_id,
            step_ref,
            to_string(event),
            %{},
            %{},
            workflow_string
          )

        {:ok, event, context_updates} ->
          insert_result_and_advance(
            config,
            instance_id,
            step_ref,
            to_string(event),
            context_updates,
            %{},
            workflow_string
          )

        {:ok, event, context_updates, metadata_updates} ->
          insert_result_and_advance(
            config,
            instance_id,
            step_ref,
            to_string(event),
            context_updates,
            metadata_updates,
            workflow_string
          )

        {:async} ->
          insert_result_and_advance(
            config,
            instance_id,
            step_ref,
            "__async__",
            %{},
            %{},
            workflow_string
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp insert_result_and_advance(
         config,
         instance_id,
         step_ref,
         event,
         context_updates,
         metadata_updates,
         workflow_string
       ) do
    workflow_module = JobMetadata.resolve_workflow(workflow_string)
    job_meta = JobMetadata.build(workflow_module, instance_id, step_ref: step_ref)

    case config.repo.transaction(fn ->
           :ok =
             StepResults.insert(
               config.repo,
               instance_id,
               step_ref,
               event,
               context_updates,
               metadata_updates
             )

           changeset =
             HephaestusOban.AdvanceWorker.new(
               %{
                 "instance_id" => instance_id,
                 "config_key" => config.key,
                 "workflow" => workflow_string
               },
               job_meta
             )

           {:ok, _job} = Oban.insert(config.oban, changeset)
           :ok
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_config(%Oban.Job{args: %{"config_key" => config_key}}) do
    :persistent_term.get({HephaestusOban, :config, config_key})
  end

  defp load_instance(config, instance_id) do
    {storage_mod, storage_name} = config.storage

    case storage_mod.get(storage_name, instance_id) do
      {:ok, instance} -> instance
      {:error, :not_found} -> raise "workflow instance not found: #{instance_id}"
    end
  end
end
