defmodule HephaestusOban.ResumeWorker do
  @moduledoc false

  use Oban.Worker, queue: :hephaestus, max_attempts: 3

  alias HephaestusOban.{AdvanceWorker, StepResults}

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{
            "instance_id" => instance_id,
            "step_ref" => step_ref,
            "event" => event
          }
        } = job
      ) do
    config = resolve_config(job)
    insert_result_and_advance(config, instance_id, step_ref, event, %{})
    :ok
  end

  def insert_result_and_advance(config, instance_id, step_ref, event, context_updates) do
    config.repo.transaction(fn ->
      :ok = StepResults.insert(config.repo, instance_id, step_ref, event, context_updates)

      %{
        "instance_id" => instance_id,
        "config_key" => config.key
      }
      |> AdvanceWorker.new()
      |> then(&Oban.insert!(config.oban, &1))
    end)
  end

  defp resolve_config(%Oban.Job{args: %{"config_key" => config_key}}) do
    :persistent_term.get({HephaestusOban, :config, config_key})
  end
end
