defmodule HephaestusOban.Workers.AdvanceWorkerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: HephaestusOban.TestRepo

  alias Hephaestus.Core.{Engine, Instance}
  alias HephaestusOban.{AdvanceWorker, StepResults}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)

    repo = HephaestusOban.TestRepo
    storage_name = :"test_aw_storage_#{System.unique_integer([:positive])}"
    :ignore = HephaestusEcto.Storage.start_link(repo: repo, name: storage_name)

    config_key = "test_aw_#{System.unique_integer([:positive])}"

    config = %{
      key: config_key,
      repo: repo,
      oban: Oban,
      storage: {HephaestusEcto.Storage, storage_name}
    }

    :persistent_term.put({HephaestusOban, :config, config_key}, config)

    on_exit(fn ->
      :persistent_term.erase({HephaestusOban, :config, config_key})
    end)

    %{repo: repo, config: config, config_key: config_key, storage_name: storage_name}
  end

  describe "perform/1 — pending instance with no step_results" do
    test "advances pending instance to running and enqueues ExecuteStepWorker with workflow + meta/tags",
         ctx do
      instance =
        Instance.new(
          HephaestusOban.Test.LinearWorkflow,
          1,
          %{},
          "testoban::adv#{System.unique_integer([:positive])}"
        )
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)

      job = advance_job(ctx.config_key, instance.id)

      assert :ok = AdvanceWorker.perform(job)

      assert {:ok, updated} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert updated.status == :running
      assert MapSet.size(updated.active_steps) > 0

      assert_enqueued_execute_steps(updated.active_steps, instance.id, ctx.config_key)

      # Validate meta/tags/workflow on one enqueued ExecuteStepWorker
      assert [exec_job | _] = all_enqueued(worker: HephaestusOban.ExecuteStepWorker)
      assert exec_job.args["workflow"] == "Elixir.HephaestusOban.Test.LinearWorkflow"
      assert exec_job.meta["heph_workflow"] == "linear_workflow"
      assert exec_job.meta["instance_id"] == instance.id
      assert is_binary(exec_job.meta["step"]) and exec_job.meta["step"] != ""
      assert "linear_workflow" in exec_job.tags
    end

    test "enqueued ExecuteStepWorker jobs include workflow_version from args", ctx do
      instance =
        Instance.new(
          HephaestusOban.Test.VersionedWorkflow,
          3,
          %{},
          "testoban::adv#{System.unique_integer([:positive])}"
        )
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)

      job = advance_job(ctx.config_key, instance.id, 3)

      assert :ok = AdvanceWorker.perform(job)

      assert [exec_job | _] = all_enqueued(worker: HephaestusOban.ExecuteStepWorker)
      assert exec_job.args["workflow_version"] == 3
    end
  end

  describe "perform/1 — applying step_results" do
    test "applies completed step results in fifo order and activates transitions", ctx do
      instance =
        Instance.new(
          HephaestusOban.Test.LinearWorkflow,
          1,
          %{},
          "testoban::adv#{System.unique_integer([:positive])}"
        )
      {:ok, instance} = Engine.advance(instance)
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)

      step_ref = to_string(HephaestusOban.Test.PassStep)
      :ok = StepResults.insert(ctx.repo, instance.id, step_ref, "done", %{"processed" => true})

      job = advance_job(ctx.config_key, instance.id)

      assert :ok = AdvanceWorker.perform(job)

      assert {:ok, updated} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert MapSet.member?(updated.completed_steps, HephaestusOban.Test.PassStep)
      assert updated.status == :running
      assert StepResults.pending_for(ctx.repo, instance.id) == []
      assert get_in(updated.context.steps, [:pass_step, :processed]) == true
      assert_enqueued_execute_steps(updated.active_steps, instance.id, ctx.config_key)
    end
  end

  describe "perform/1 — instance reaches completion" do
    test "marks instance as completed when the workflow reaches the done step", ctx do
      instance =
        Instance.new(
          HephaestusOban.Test.LinearWorkflow,
          1,
          %{},
          "testoban::adv#{System.unique_integer([:positive])}"
        )
      {:ok, instance} = Engine.advance(instance)
      instance = Engine.complete_step(instance, HephaestusOban.Test.PassStep, :done, %{})
      instance = Engine.activate_transitions(instance, HephaestusOban.Test.PassStep, :done)
      instance = Engine.complete_step(instance, Hephaestus.Steps.Done, :done, %{})
      instance = Engine.check_completion(instance)
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)

      job = advance_job(ctx.config_key, instance.id)

      assert :ok = AdvanceWorker.perform(job)

      assert {:ok, final} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert final.status == :completed

      refute_enqueued(
        worker: HephaestusOban.ExecuteStepWorker,
        args: %{"instance_id" => instance.id}
      )
    end
  end

  describe "perform/1 — async sentinel handling" do
    test "__async__ step_result sets instance to waiting with current_step", ctx do
      instance =
        Instance.new(
          HephaestusOban.Test.AsyncWorkflow,
          1,
          %{},
          "testoban::adv#{System.unique_integer([:positive])}"
        )
      {:ok, instance} = Engine.advance(instance)
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)

      step_ref = to_string(HephaestusOban.Test.AsyncStep)
      :ok = StepResults.insert(ctx.repo, instance.id, step_ref, "__async__", %{})

      job = advance_job(ctx.config_key, instance.id)

      assert :ok = AdvanceWorker.perform(job)

      assert {:ok, updated} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert updated.status == :waiting
      assert updated.current_step == HephaestusOban.Test.AsyncStep
      assert StepResults.pending_for(ctx.repo, instance.id) == []
    end
  end

  describe "perform/1 — resume from waiting" do
    test "resume step_result on waiting instance transitions to running and completes the step",
         ctx do
      instance =
        Instance.new(
          HephaestusOban.Test.AsyncWorkflow,
          1,
          %{},
          "testoban::adv#{System.unique_integer([:positive])}"
        )
      {:ok, instance} = Engine.advance(instance)
      instance = %{instance | status: :waiting, current_step: HephaestusOban.Test.AsyncStep}
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)

      step_ref = to_string(HephaestusOban.Test.AsyncStep)
      :ok = StepResults.insert(ctx.repo, instance.id, step_ref, "resumed", %{})

      job = advance_job(ctx.config_key, instance.id)

      assert :ok = AdvanceWorker.perform(job)

      assert {:ok, updated} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      refute updated.status == :waiting
      refute updated.current_step == HephaestusOban.Test.AsyncStep
      assert MapSet.member?(updated.completed_steps, HephaestusOban.Test.AsyncStep)
    end
  end

  describe "perform/1 — discarded step detection" do
    test "discarded ExecuteStepWorker marks the workflow failed", ctx do
      instance =
        Instance.new(
          HephaestusOban.Test.LinearWorkflow,
          1,
          %{},
          "testoban::adv#{System.unique_integer([:positive])}"
        )
      {:ok, instance} = Engine.advance(instance)
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)

      step_ref = to_string(HephaestusOban.Test.PassStep)
      insert_discarded_job(ctx.repo, instance.id, step_ref, ctx.config_key)

      job = advance_job(ctx.config_key, instance.id)

      assert :ok = AdvanceWorker.perform(job)

      assert {:ok, updated} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert updated.status == :failed
    end
  end

  defp advance_job(config_key, instance_id, workflow_version \\ 1) do
    %Oban.Job{
      args: %{
        "instance_id" => instance_id,
        "config_key" => config_key,
        "workflow_version" => workflow_version
      }
    }
  end

  defp assert_enqueued_execute_steps(active_steps, instance_id, config_key) do
    active_steps
    |> MapSet.to_list()
    |> Enum.each(fn step_module ->
      assert_enqueued(
        worker: HephaestusOban.ExecuteStepWorker,
        args: %{
          "instance_id" => instance_id,
          "config_key" => config_key,
          "step_ref" => to_string(step_module),
          "workflow" => "Elixir.HephaestusOban.Test.LinearWorkflow"
        }
      )
    end)
  end

  defp insert_discarded_job(repo, instance_id, step_ref, config_key) do
    repo.insert!(%Oban.Job{
      worker: "HephaestusOban.ExecuteStepWorker",
      args: %{"instance_id" => instance_id, "step_ref" => step_ref, "config_key" => config_key},
      queue: "hephaestus",
      state: "discarded",
      max_attempts: 5,
      attempt: 5
    })
  end

end
