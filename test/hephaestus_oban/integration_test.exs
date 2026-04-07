defmodule HephaestusOban.IntegrationTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: HephaestusOban.TestRepo

  alias HephaestusOban.{Runner, StepResults}

  defmodule ContextWorkflow do
    use Hephaestus.Workflow

    @impl true
    def start, do: HephaestusOban.Test.PassWithContextStep

    @impl true
    def transit(HephaestusOban.Test.PassWithContextStep, :done, _ctx), do: Hephaestus.Steps.Done
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(HephaestusOban.TestRepo, {:shared, self()})

    repo = HephaestusOban.TestRepo
    storage_name = :"test_int_storage_#{System.unique_integer([:positive])}"
    :ignore = HephaestusEcto.Storage.start_link(repo: repo, name: storage_name)

    config_key = "test_int_#{System.unique_integer([:positive])}"

    opts = [
      config_key: config_key,
      repo: repo,
      oban: Oban,
      storage: {HephaestusEcto.Storage, storage_name}
    ]

    :ignore = Runner.start_link(opts)

    on_exit(fn ->
      :persistent_term.erase({HephaestusOban, :config, config_key})
      :telemetry.detach("hephaestus-step-discarded")
    end)

    %{config_key: config_key, opts: opts, repo: repo, storage_name: storage_name}
  end

  describe "linear workflow end-to-end" do
    test "start -> advance -> execute -> complete", ctx do
      assert {:ok, instance_id} =
               Runner.start_instance(HephaestusOban.Test.LinearWorkflow, %{}, runner_opts(ctx))

      assert_enqueued(
        worker: HephaestusOban.AdvanceWorker,
        args: %{"instance_id" => instance_id, "config_key" => ctx.config_key}
      )

      assert drain_hephaestus_queue() == 5

      final = load_instance(ctx.storage_name, instance_id)

      assert final.status == :completed
      assert final.current_step == nil
      assert MapSet.member?(final.completed_steps, HephaestusOban.Test.PassStep)
      assert MapSet.member?(final.completed_steps, Hephaestus.Steps.Done)
      assert StepResults.pending_for(ctx.repo, instance_id) == []
    end
  end

  describe "async workflow end-to-end" do
    test "start -> async -> waiting -> resume -> complete", ctx do
      assert {:ok, instance_id} =
               Runner.start_instance(HephaestusOban.Test.AsyncWorkflow, %{}, runner_opts(ctx))

      assert drain_hephaestus_queue() == 3

      waiting = load_instance(ctx.storage_name, instance_id)

      assert waiting.status == :waiting
      assert waiting.current_step == HephaestusOban.Test.AsyncStep
      assert :ok = Runner.resume(instance_id, :resumed)

      assert_enqueued(
        worker: HephaestusOban.ResumeWorker,
        args: %{
          "instance_id" => instance_id,
          "step_ref" => to_string(HephaestusOban.Test.AsyncStep),
          "event" => "resumed",
          "config_key" => ctx.config_key
        }
      )

      assert drain_hephaestus_queue() == 4

      final = load_instance(ctx.storage_name, instance_id)

      assert final.status == :completed
      assert final.current_step == nil
      assert MapSet.member?(final.completed_steps, HephaestusOban.Test.AsyncStep)
      assert MapSet.member?(final.completed_steps, Hephaestus.Steps.Done)
      assert StepResults.pending_for(ctx.repo, instance_id) == []
    end
  end

  describe "context propagation end-to-end" do
    test "step context_updates are available after workflow completes", ctx do
      assert {:ok, instance_id} = Runner.start_instance(ContextWorkflow, %{}, runner_opts(ctx))

      assert drain_hephaestus_queue() == 5

      final = load_instance(ctx.storage_name, instance_id)

      assert final.status == :completed
      assert MapSet.member?(final.completed_steps, HephaestusOban.Test.PassWithContextStep)
      assert get_in(final.context.steps, [:pass_with_context_step, :processed]) == true
      assert StepResults.pending_for(ctx.repo, instance_id) == []
    end
  end

  defp runner_opts(ctx) do
    [storage: {HephaestusEcto.Storage, ctx.storage_name}, config_key: ctx.config_key, oban: Oban]
  end

  defp load_instance(storage_name, instance_id) do
    {:ok, instance} = HephaestusEcto.Storage.get(storage_name, instance_id)
    instance
  end

  defp drain_hephaestus_queue do
    1..10
    |> Enum.reduce_while(0, fn _, total ->
      result = Oban.drain_queue(queue: :hephaestus)

      if result.failure > 0 or result.discard > 0 do
        flunk("queue drain failed: #{inspect(result)}")
      end

      if result.success == 0 do
        {:halt, total}
      else
        {:cont, total + result.success}
      end
    end)
  end
end
