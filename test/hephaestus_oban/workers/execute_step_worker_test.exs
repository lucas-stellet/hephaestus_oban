defmodule HephaestusOban.Workers.ExecuteStepWorkerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: HephaestusOban.TestRepo

  alias Hephaestus.Core.{Engine, Instance}
  alias HephaestusOban.{ExecuteStepWorker, StepResults}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)

    repo = HephaestusOban.TestRepo
    storage_name = :"test_esw_storage_#{System.unique_integer([:positive])}"
    :ignore = HephaestusEcto.Storage.start_link(repo: repo, name: storage_name)

    config_key = "test_esw_#{System.unique_integer([:positive])}"

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

    %{repo: repo, config_key: config_key, storage_name: storage_name}
  end

  describe "perform/1 — synchronous step success" do
    test "executes step, inserts step_result with event, enqueues AdvanceWorker", ctx do
      # Arrange
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)
      step_ref = to_string(HephaestusOban.Test.PassStep)
      job = execute_job(ctx.config_key, instance.id, step_ref)

      # Act
      assert :ok = ExecuteStepWorker.perform(job)

      # Assert
      [result] = StepResults.pending_for(ctx.repo, instance.id)
      assert result.step_ref == step_ref
      assert result.event == "done"

      assert_enqueued(
        worker: HephaestusOban.AdvanceWorker,
        args: %{"instance_id" => instance.id, "config_key" => ctx.config_key}
      )
    end
  end

  describe "perform/1 — step with context updates" do
    test "stores context_updates in step_result", ctx do
      # Arrange
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      instance = %{instance | active_steps: MapSet.new([HephaestusOban.Test.PassWithContextStep])}
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)
      step_ref = to_string(HephaestusOban.Test.PassWithContextStep)
      job = execute_job(ctx.config_key, instance.id, step_ref)

      # Act
      assert :ok = ExecuteStepWorker.perform(job)

      # Assert
      [result] = StepResults.pending_for(ctx.repo, instance.id)
      assert result.context_updates == %{"processed" => true}
    end
  end

  describe "perform/1 — async step" do
    test "inserts __async__ sentinel step_result and enqueues AdvanceWorker", ctx do
      # Arrange
      instance = Instance.new(HephaestusOban.Test.AsyncWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)
      step_ref = to_string(HephaestusOban.Test.AsyncStep)
      job = execute_job(ctx.config_key, instance.id, step_ref)

      # Act
      assert :ok = ExecuteStepWorker.perform(job)

      # Assert
      [result] = StepResults.pending_for(ctx.repo, instance.id)
      assert result.event == "__async__"
      assert result.step_ref == step_ref

      assert_enqueued(
        worker: HephaestusOban.AdvanceWorker,
        args: %{"instance_id" => instance.id, "config_key" => ctx.config_key}
      )
    end
  end

  describe "perform/1 — step failure" do
    test "returns error for Oban retry when step fails", ctx do
      # Arrange
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      instance = %{instance | active_steps: MapSet.new([HephaestusOban.Test.FailStep])}
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)
      step_ref = to_string(HephaestusOban.Test.FailStep)
      job = execute_job(ctx.config_key, instance.id, step_ref)

      # Act
      result = ExecuteStepWorker.perform(job)

      # Assert
      assert {:error, :forced_failure} = result
      assert StepResults.pending_for(ctx.repo, instance.id) == []
    end
  end

  describe "perform/1 — idempotency" do
    test "skips execution when step_result already exists", ctx do
      # Arrange
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)
      step_ref = to_string(HephaestusOban.Test.PassStep)
      :ok = StepResults.insert(ctx.repo, instance.id, step_ref, "done", %{})
      job = execute_job(ctx.config_key, instance.id, step_ref)

      # Act
      result = ExecuteStepWorker.perform(job)

      # Assert
      assert {:ok, :already_recorded} = result
      assert length(StepResults.pending_for(ctx.repo, instance.id)) == 1
    end
  end

  describe "perform/1 — atomicity" do
    test "step_result and AdvanceWorker enqueue are in same transaction", ctx do
      # Arrange
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)
      step_ref = to_string(HephaestusOban.Test.PassStep)
      job = execute_job(ctx.config_key, instance.id, step_ref)

      # Act
      assert :ok = ExecuteStepWorker.perform(job)

      # Assert
      assert length(StepResults.pending_for(ctx.repo, instance.id)) == 1

      assert_enqueued(
        worker: HephaestusOban.AdvanceWorker,
        args: %{"instance_id" => instance.id, "config_key" => ctx.config_key}
      )
    end
  end

  defp execute_job(config_key, instance_id, step_ref) do
    %Oban.Job{
      args: %{
        "instance_id" => instance_id,
        "step_ref" => step_ref,
        "config_key" => config_key
      }
    }
  end
end
