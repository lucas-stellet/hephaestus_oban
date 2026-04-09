defmodule HephaestusOban.AdvanceWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :hephaestus,
    unique: [
      keys: [:instance_id],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  alias Hephaestus.Core.Engine
  alias HephaestusOban.{RetryConfig, StepResults}
  alias HephaestusOban.JobMetadata

  @execute_step_worker HephaestusOban.ExecuteStepWorker |> Module.split() |> Enum.join(".")
  @cancellable_states ["available", "scheduled", "executing", "retryable"]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"instance_id" => instance_id} = args} = job) do
    config = resolve_config(job)
    workflow_version = Map.get(args, "workflow_version", 1)
    <<lock_key::signed-integer-64, _rest::binary>> = Ecto.UUID.dump!(instance_id)
    discarded = detect_discarded_steps(config, instance_id)

    result =
      config.repo.transaction(fn ->
        config.repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])

        instance = load_instance(config, instance_id)
        pending = StepResults.pending_for(config.repo, instance_id)
        instance = apply_step_results(instance, pending)

        if discarded != [] do
          instance = fail_workflow(config, instance)
          persist(config, instance)
          StepResults.mark_processed(config.repo, pending)
          {:failed, instance}
        else
          {:ok, instance} = Engine.advance(instance)
          persist(config, instance)
          StepResults.mark_processed(config.repo, pending)
          {:continue, instance}
        end
      end)

    case result do
      {:ok, {:failed, instance}} ->
        cancel_pending_jobs(config, instance)
        :ok

      {:ok, {:continue, instance}} ->
        case instance do
          %{status: status} when status in [:completed, :failed, :waiting] ->
            :ok

          %{active_steps: active_steps} ->
            active_steps
            |> MapSet.to_list()
            |> Enum.each(
              &enqueue_execute_step(
                config,
                instance_id,
                instance.workflow,
                &1,
                instance.runtime_metadata,
                workflow_version
              )
            )

            :ok
        end

      {:error, reason} ->
        {:error, reason}
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

  defp persist(config, instance) do
    {storage_mod, storage_name} = config.storage
    storage_mod.put(storage_name, instance)
  end

  defp detect_discarded_steps(config, instance_id) do
    config.repo.all(
      from(job in Oban.Job,
        where: job.worker == ^@execute_step_worker and job.state == "discarded",
        where: fragment("?->>? = ?", job.args, "instance_id", ^instance_id)
      )
    )
  end

  defp fail_workflow(_config, instance) do
    %{instance | status: :failed, current_step: nil}
  end

  defp cancel_pending_jobs(config, instance) do
    query =
      from(job in Oban.Job,
        where: job.state in ^@cancellable_states,
        where: fragment("?->>? = ?", job.args, "instance_id", ^instance.id)
      )

    {:ok, _count} = Oban.cancel_all_jobs(config.oban, query)
    :ok
  end

  defp enqueue_execute_step(
         config,
         instance_id,
         workflow_module,
         step_module,
         runtime_metadata,
         workflow_version
       ) do
    retry = RetryConfig.resolve(step_module, workflow_module)

    job_meta =
      JobMetadata.build(workflow_module, instance_id,
        step_ref: step_module,
        runtime_metadata: runtime_metadata
      )

    changeset =
      Oban.Job.new(
        %{
          "instance_id" => instance_id,
          "config_key" => config.key,
          "step_ref" => to_string(step_module),
          "workflow" => to_string(workflow_module),
          "workflow_version" => workflow_version
        },
        [
          queue: :hephaestus,
          worker: HephaestusOban.ExecuteStepWorker,
          max_attempts: retry.max_attempts
        ] ++ job_meta
      )

    Oban.insert(config.oban, changeset)

    :ok
  end

  defp apply_step_results(instance, pending) do
    case pending do
      [] ->
        instance

      _results ->
        pending
        |> Enum.reduce(instance, fn step_result, acc ->
          step_module = String.to_existing_atom(step_result.step_ref)

          if step_result.event == "__async__" do
            %{acc | status: :waiting, current_step: step_module}
          else
            event = String.to_existing_atom(step_result.event)

            acc =
              if acc.status == :waiting do
                %{acc | status: :running, current_step: nil}
              else
                acc
              end

            acc
            |> Engine.complete_step(
              step_module,
              event,
              step_result.context_updates,
              step_result.metadata_updates || %{}
            )
            |> Engine.activate_transitions(step_module, event)
          end
        end)
        |> Engine.check_completion()
    end
  end
end
