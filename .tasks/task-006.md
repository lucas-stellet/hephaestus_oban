# Task 006: ExecuteStepWorker — step executor with idempotency

**Wave**: 3 | **Effort**: M
**Depends on**: task-005
**Blocks**: task-009

## Objective

Implement the ExecuteStepWorker — an Oban worker that executes a single workflow step, writes the result to the `step_results` table, and enqueues an AdvanceWorker. It never touches the Instance directly. Provides idempotency via step_results existence check.

## Files

**Create:** `lib/hephaestus_oban/workers/execute_step_worker.ex` — worker implementation
**Create:** `test/hephaestus_oban/workers/execute_step_worker_test.exs` — unit tests
**Read:** `lib/hephaestus_oban/workers/advance_worker.ex` — AdvanceWorker (enqueued after result insert)
**Read:** `lib/hephaestus_oban/step_results.ex` — StepResults CRUD

## Requirements

### Worker configuration

```elixir
use Oban.Worker,
  queue: :hephaestus,
  unique: [keys: [:instance_id, :step_ref], period: :infinity,
           states: [:available, :scheduled, :executing, :retryable]]
```

### perform/1 flow

1. Resolve config from `job.args["config_key"]`
2. **Idempotency check**: `StepResults.exists?(repo, instance_id, step_ref)` — if true, return `{:ok, :already_recorded}`
3. Load instance from storage (read-only)
4. `step_module = String.to_existing_atom(step_ref)`
5. `Engine.execute_step(instance, step_module)` → dispatch on return value

### insert_result_and_advance/5

Wraps step_result insert + AdvanceWorker enqueue in `Repo.transaction` for atomicity.

## Test file

`test/hephaestus_oban/workers/execute_step_worker_test.exs`

## Test sequence

```elixir
defmodule HephaestusOban.Workers.ExecuteStepWorkerTest do
  use ExUnit.Case, async: false

  alias Hephaestus.Core.{Engine, Instance}
  alias HephaestusOban.{ExecuteStepWorker, StepResults}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)
    repo = HephaestusOban.TestRepo

    storage_name = :"test_esw_storage_#{System.unique_integer([:positive])}"
    {:ok, _} = HephaestusEcto.Storage.start_link(repo: repo, name: storage_name)

    config_key = "test_esw_#{System.unique_integer([:positive])}"
    config = %{
      key: config_key,
      repo: repo,
      oban: Oban,
      storage: {HephaestusEcto.Storage, storage_name}
    }
    :persistent_term.put({HephaestusOban, :config, config_key}, config)

    on_exit(fn -> :persistent_term.erase({HephaestusOban, :config, config_key}) end)

    %{repo: repo, config: config, config_key: config_key, storage_name: storage_name}
  end

  describe "perform/1 — synchronous step success" do
    test "executes step, inserts step_result with event, enqueues AdvanceWorker", ctx do
      # Arrange — running instance with PassStep active
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      step_ref = to_string(HephaestusOban.Test.PassStep)

      # Act
      job = build_job(ctx.config_key, instance.id, step_ref)
      assert :ok = ExecuteStepWorker.perform(job)

      # Assert — step_result inserted with event "done"
      [result] = StepResults.pending_for(ctx.repo, instance.id)
      assert result.step_ref == step_ref
      assert result.event == "done"

      # Assert — AdvanceWorker enqueued
      assert_enqueued(worker: HephaestusOban.AdvanceWorker,
                      args: %{"instance_id" => instance.id})
    end
  end

  describe "perform/1 — step with context updates" do
    test "stores context_updates in step_result", ctx do
      # Arrange — running instance with PassWithContextStep active
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      # Manually set PassWithContextStep as active
      instance = %{instance | active_steps: MapSet.new([HephaestusOban.Test.PassWithContextStep])}
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      step_ref = to_string(HephaestusOban.Test.PassWithContextStep)

      # Act
      job = build_job(ctx.config_key, instance.id, step_ref)
      assert :ok = ExecuteStepWorker.perform(job)

      # Assert — context_updates stored
      [result] = StepResults.pending_for(ctx.repo, instance.id)
      assert result.context_updates == %{"processed" => true}
    end
  end

  describe "perform/1 — async step" do
    test "inserts __async__ sentinel step_result and enqueues AdvanceWorker", ctx do
      # Arrange — running instance with AsyncStep active
      instance = Instance.new(HephaestusOban.Test.AsyncWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      step_ref = to_string(HephaestusOban.Test.AsyncStep)

      # Act
      job = build_job(ctx.config_key, instance.id, step_ref)
      assert :ok = ExecuteStepWorker.perform(job)

      # Assert — sentinel __async__ step_result inserted
      [result] = StepResults.pending_for(ctx.repo, instance.id)
      assert result.event == "__async__"
      assert result.step_ref == step_ref

      # Assert — AdvanceWorker enqueued
      assert_enqueued(worker: HephaestusOban.AdvanceWorker,
                      args: %{"instance_id" => instance.id})
    end
  end

  describe "perform/1 — step failure" do
    test "returns error for Oban retry when step fails", ctx do
      # Arrange — running instance with FailStep active
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      instance = %{instance | active_steps: MapSet.new([HephaestusOban.Test.FailStep])}
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      step_ref = to_string(HephaestusOban.Test.FailStep)

      # Act
      job = build_job(ctx.config_key, instance.id, step_ref)
      result = ExecuteStepWorker.perform(job)

      # Assert — returns error tuple so Oban retries
      assert {:error, :forced_failure} = result

      # Assert — no step_result inserted (will be inserted on success)
      assert StepResults.pending_for(ctx.repo, instance.id) == []
    end
  end

  describe "perform/1 — idempotency" do
    test "skips execution when step_result already exists", ctx do
      # Arrange — step_result already inserted (e.g., from previous attempt)
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      step_ref = to_string(HephaestusOban.Test.PassStep)
      :ok = StepResults.insert(ctx.repo, instance.id, step_ref, "done", %{})

      # Act
      job = build_job(ctx.config_key, instance.id, step_ref)
      result = ExecuteStepWorker.perform(job)

      # Assert — skips execution, returns already_recorded
      assert {:ok, :already_recorded} = result

      # Assert — still only one step_result
      assert length(StepResults.pending_for(ctx.repo, instance.id)) == 1
    end
  end

  describe "perform/1 — atomicity" do
    test "step_result and AdvanceWorker enqueue are in same transaction", ctx do
      # Arrange
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      step_ref = to_string(HephaestusOban.Test.PassStep)

      # Act
      job = build_job(ctx.config_key, instance.id, step_ref)
      assert :ok = ExecuteStepWorker.perform(job)

      # Assert — both step_result and AdvanceWorker exist
      assert length(StepResults.pending_for(ctx.repo, instance.id)) == 1
      assert_enqueued(worker: HephaestusOban.AdvanceWorker,
                      args: %{"instance_id" => instance.id})
    end
  end

  # --- helpers ---

  defp build_job(config_key, instance_id, step_ref) do
    %Oban.Job{
      args: %{
        "instance_id" => instance_id,
        "step_ref" => step_ref,
        "config_key" => config_key
      }
    }
  end
end
```

## Acceptance criteria

- [ ] All 6 tests pass
- [ ] Idempotency check prevents re-execution
- [ ] All 4 Engine return values handled correctly
- [ ] Atomicity via Repo.transaction confirmed
- [ ] No regressions (`mix test`)
