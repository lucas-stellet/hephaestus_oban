defmodule HephaestusOban.FailureHandler do
  @moduledoc false

  @execute_step_worker HephaestusOban.ExecuteStepWorker |> Module.split() |> Enum.join(".")
  alias HephaestusOban.JobMetadata

  def attach do
    :telemetry.attach(
      "hephaestus-step-discarded",
      [:oban, :job, :stop],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event([:oban, :job, :stop], _measure, %{job: job, state: :discard}, _config) do
    if job.worker == @execute_step_worker do
      config = resolve_config(job)

      %{
        "instance_id" => instance_id,
        "config_key" => config_key,
        "step_ref" => step_ref,
        "workflow" => workflow_string
      } = job.args

      workflow_module = JobMetadata.resolve_workflow(workflow_string)
      job_meta = JobMetadata.build(workflow_module, instance_id, step_ref: step_ref)

      %{
        "instance_id" => instance_id,
        "config_key" => config_key,
        "workflow" => workflow_string
      }
      |> HephaestusOban.AdvanceWorker.new(job_meta)
      |> then(&Oban.insert(config.oban, &1))
    else
      :ok
    end
  end

  def handle_event(_event, _measure, _meta, _config), do: :ok

  defp resolve_config(%Oban.Job{args: %{"config_key" => config_key}}) do
    :persistent_term.get({HephaestusOban, :config, config_key})
  end
end
