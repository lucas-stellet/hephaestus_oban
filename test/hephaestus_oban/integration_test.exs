defmodule HephaestusOban.IntegrationTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: HephaestusOban.TestRepo

  alias HephaestusOban.{Runner, StepResults}

  defmodule ContextWorkflow do
    use Hephaestus.Workflow, unique: [key: "testoban"]

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

  describe "meta/tags propagation" do
    test "start_instance → AdvanceWorker has workflow meta (no step)", ctx do
      opts = runner_opts(ctx)
      {:ok, instance_id} = Runner.start_instance(HephaestusOban.Test.TaggedWorkflow, %{}, opts)

      job =
        all_enqueued(worker: HephaestusOban.AdvanceWorker)
        |> Enum.find(fn j -> j.args["instance_id"] == instance_id end)

      assert job
      assert job.args["workflow"] == to_string(HephaestusOban.Test.TaggedWorkflow)
      assert "tagged_workflow" in job.tags
      assert "onboarding" in job.tags
      assert "growth" in job.tags
      assert job.meta["heph_workflow"] == "tagged_workflow"
      assert job.meta["instance_id"] == instance_id
      assert job.meta["team"] == "growth"
      refute Map.has_key?(job.meta, "step")
    end

    test "meta/tags propagate through advance → execute → advance chain", ctx do
      opts = runner_opts(ctx)
      {:ok, instance_id} = Runner.start_instance(HephaestusOban.Test.TaggedWorkflow, %{}, opts)

      # Process initial AdvanceWorker
      advance_job =
        all_enqueued(worker: HephaestusOban.AdvanceWorker)
        |> Enum.find(fn j -> j.args["instance_id"] == instance_id end)

      assert advance_job
      perform_job(HephaestusOban.AdvanceWorker, advance_job.args)

      # Check ExecuteStepWorker
      exec_job =
        all_enqueued(worker: HephaestusOban.ExecuteStepWorker)
        |> Enum.find(fn j -> j.args["instance_id"] == instance_id end)

      assert exec_job
      assert exec_job.args["workflow"] == to_string(HephaestusOban.Test.TaggedWorkflow)
      assert exec_job.meta["step"] == "pass_step"
      assert exec_job.meta["team"] == "growth"
      assert "onboarding" in exec_job.tags

      # Process ExecuteStepWorker — creates next AdvanceWorker
      import Ecto.Query
      query = from(j in Oban.Job,
        where: j.worker == ^"HephaestusOban.AdvanceWorker",
        where: fragment("?->>? = ?", j.args, "instance_id", ^instance_id)
      )
      {:ok, _} = Oban.cancel_all_jobs(Oban, query)
      perform_job(HephaestusOban.ExecuteStepWorker, exec_job.args)

      # Check the chained AdvanceWorker preserves workflow + step
      chained_job =
        all_enqueued(worker: HephaestusOban.AdvanceWorker)
        |> Enum.find(fn j -> j.args["instance_id"] == instance_id and Map.has_key?(j.meta, "step") end)

      assert chained_job
      assert chained_job.args["workflow"] == to_string(HephaestusOban.Test.TaggedWorkflow)
      assert chained_job.meta["heph_workflow"] == "tagged_workflow"
      assert chained_job.meta["instance_id"] == instance_id
      assert chained_job.meta["team"] == "growth"
    end

    test "untagged workflow gets system meta only", ctx do
      opts = runner_opts(ctx)
      {:ok, instance_id} = Runner.start_instance(HephaestusOban.Test.LinearWorkflow, %{}, opts)

      job =
        all_enqueued(worker: HephaestusOban.AdvanceWorker)
        |> Enum.find(fn j -> j.args["instance_id"] == instance_id end)

      assert job
      assert job.meta["heph_workflow"] == "linear_workflow"
      assert job.meta["instance_id"] == instance_id
      refute Map.has_key?(job.meta, "team")
      assert job.tags == ["linear_workflow"]
    end
  end

  defp runner_opts(ctx) do
    [
      storage: {HephaestusEcto.Storage, ctx.storage_name},
      config_key: ctx.config_key,
      oban: Oban,
      id: "testoban::int#{System.unique_integer([:positive])}"
    ]
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
