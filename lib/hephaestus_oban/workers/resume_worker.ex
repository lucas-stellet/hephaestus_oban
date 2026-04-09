defmodule HephaestusOban.ResumeWorker do
  @moduledoc false

  use Oban.Worker, queue: :hephaestus, max_attempts: 3

  alias HephaestusOban.{AdvanceWorker, JobMetadata, StepResults}

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args:
            %{
              "instance_id" => instance_id,
              "step_ref" => step_ref,
              "event" => event,
              "workflow" => workflow_string
            } = args
        } = job
      ) do
    config = resolve_config(job)
    workflow_version = Map.get(args, "workflow_version", 1)

    insert_result_and_advance(
      config,
      instance_id,
      step_ref,
      event,
      %{},
      workflow_string,
      workflow_version
    )

    :ok
  end

  def insert_result_and_advance(
        config,
        instance_id,
        step_ref,
        event,
        context_updates,
        workflow_string,
        workflow_version
      ) do
    workflow_module = JobMetadata.resolve_workflow(workflow_string)
    job_meta = JobMetadata.build(workflow_module, instance_id, step_ref: step_ref)

    config.repo.transaction(fn ->
      :ok =
        StepResults.insert(
          config.repo,
          instance_id,
          step_ref,
          event,
          context_updates,
          %{},
          workflow_version
        )

      %{
        "instance_id" => instance_id,
        "config_key" => config.key,
        "workflow" => workflow_string,
        "workflow_version" => workflow_version
      }
      |> AdvanceWorker.new(job_meta)
      |> then(&Oban.insert!(config.oban, &1))
    end)
  end

  defp resolve_config(%Oban.Job{args: %{"config_key" => config_key}}) do
    :persistent_term.get({HephaestusOban, :config, config_key})
  end
end
