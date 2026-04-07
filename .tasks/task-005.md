# Task 005: AdvanceWorker — single Instance writer with advisory lock

**Wave**: 2 | **Effort**: L
**Depends on**: task-002, task-003
**Blocks**: task-006, task-007, task-008

## Objective

Implement the AdvanceWorker — the orchestrator Oban worker that is the **single writer** for workflow Instances. It reads pending step_results, applies them to the Instance via Engine functions, persists the updated Instance, and enqueues ExecuteStepWorkers for newly activated steps. Serialized per instance via Oban unique constraint + PostgreSQL advisory lock.

## Files

**Create:** `lib/hephaestus_oban/workers/advance_worker.ex` — worker implementation
**Create:** `test/hephaestus_oban/workers/advance_worker_test.exs` — unit tests
**Read:** `lib/hephaestus_oban/step_results.ex` — StepResults CRUD
**Read:** `lib/hephaestus_oban/retry_config.ex` — RetryConfig resolution

## Requirements

### Worker configuration

```elixir
use Oban.Worker,
  queue: :hephaestus,
  unique: [keys: [:instance_id], period: :infinity,
           states: [:available, :scheduled, :executing, :retryable]]
```

### perform/1 flow

1. **Resolve config** from `job.args["config_key"]` via `:persistent_term.get({HephaestusOban, :config, config_key})`
2. **Compute advisory lock key**: `<<lock_key::signed-integer-64, _rest::binary>> = Ecto.UUID.dump!(instance_id)`
3. **Detect discarded steps** BEFORE entering transaction
4. **Enter `Repo.transaction`**:
   a. `repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])`
   b. Load instance from storage
   c. `StepResults.pending_for(repo, instance_id)`
   d. `apply_step_results(instance, pending)`
   e. If discarded → fail workflow, persist, mark processed, return `{:failed, instance}`
   f. Else → `Engine.advance(instance)`, persist, mark processed, return `{:continue, instance}`
5. **Post-transaction**:
   - `{:failed, _}` → cancel pending jobs, `:ok`
   - `{:continue, instance}` with `:completed`/`:failed`/`:waiting` → `:ok`
   - `{:continue, instance}` with active_steps → enqueue ExecuteStepWorker per step, `:ok`

### apply_step_results/2 logic

```
for each step_result (FIFO order):
  step_module = String.to_existing_atom(step_result.step_ref)

  if step_result.event == "__async__":
    instance = %{instance | status: :waiting, current_step: step_module}
  else:
    event = String.to_existing_atom(step_result.event)
    # Resume: waiting → running before completing
    instance = if instance.status == :waiting, do: %{instance | status: :running, current_step: nil}, else: instance
    instance = Engine.complete_step(instance, step_module, event, step_result.context_updates)
    instance = Engine.activate_transitions(instance, step_module, event)

instance = Engine.check_completion(instance)
```

### Helper functions

- `resolve_config(job)` — reads from persistent_term
- `load_instance(config, instance_id)` — loads via storage
- `persist(config, instance)` — persists via storage
- `detect_discarded_steps(config, instance_id)` — queries Oban jobs table
- `fail_workflow(config, instance)` — sets `%{instance | status: :failed}`
- `cancel_pending_jobs(config, instance)` — cancels remaining Oban jobs for this instance
- `enqueue_execute_step(config, instance_id, step_module)` — creates ExecuteStepWorker with retry config

## Test file

`test/hephaestus_oban/workers/advance_worker_test.exs`

## Test sequence

```elixir
defmodule HephaestusOban.Workers.AdvanceWorkerTest do
  use ExUnit.Case, async: false

  alias Hephaestus.Core.{Engine, Instance}
  alias HephaestusOban.{AdvanceWorker, StepResults}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)
    repo = HephaestusOban.TestRepo

    storage_name = :"test_aw_storage_#{System.unique_integer([:positive])}"
    {:ok, _} = HephaestusEcto.Storage.start_link(repo: repo, name: storage_name)

    config_key = "test_aw_#{System.unique_integer([:positive])}"
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

  describe "perform/1 — pending instance with no step_results" do
    test "advances pending instance to running and enqueues ExecuteStepWorkers", ctx do
      # Arrange
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      # Act
      job = build_job(ctx.config_key, instance.id)
      assert :ok = AdvanceWorker.perform(job)

      # Assert — instance is now running
      {:ok, updated} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert updated.status == :running
      assert MapSet.size(updated.active_steps) > 0

      # Assert — ExecuteStepWorker jobs enqueued
      assert_enqueued_execute_steps(updated.active_steps, instance.id)
    end
  end

  describe "perform/1 — applying step_results" do
    test "applies completed step result and activates transitions", ctx do
      # Arrange — instance is running with PassStep active
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      # Insert a step_result as if ExecuteStepWorker completed
      step_ref = to_string(HephaestusOban.Test.PassStep)
      :ok = StepResults.insert(ctx.repo, instance.id, step_ref, "done", %{})

      # Act
      job = build_job(ctx.config_key, instance.id)
      assert :ok = AdvanceWorker.perform(job)

      # Assert — step completed, transitions activated
      {:ok, updated} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert MapSet.member?(updated.completed_steps, HephaestusOban.Test.PassStep)
      # Step results marked processed
      assert StepResults.pending_for(ctx.repo, instance.id) == []
    end
  end

  describe "perform/1 — instance reaches completion" do
    test "marks instance as completed when workflow reaches Done step", ctx do
      # Arrange — instance with all steps completed except Done
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      instance = Engine.complete_step(instance, HephaestusOban.Test.PassStep, :done, %{})
      instance = Engine.activate_transitions(instance, HephaestusOban.Test.PassStep, :done)
      # Done step should now be active — complete it
      instance = Engine.complete_step(instance, Hephaestus.Steps.Done, :done, %{})
      instance = Engine.check_completion(instance)
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      # Act
      job = build_job(ctx.config_key, instance.id)
      assert :ok = AdvanceWorker.perform(job)

      # Assert — no more jobs enqueued
      {:ok, final} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert final.status == :completed
    end
  end

  describe "perform/1 — async sentinel handling" do
    test "__async__ step_result sets instance to waiting with current_step", ctx do
      # Arrange — instance running with AsyncStep active
      instance = Instance.new(HephaestusOban.Test.AsyncWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      step_ref = to_string(HephaestusOban.Test.AsyncStep)
      :ok = StepResults.insert(ctx.repo, instance.id, step_ref, "__async__", %{})

      # Act
      job = build_job(ctx.config_key, instance.id)
      assert :ok = AdvanceWorker.perform(job)

      # Assert — instance is waiting, current_step is AsyncStep
      {:ok, updated} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert updated.status == :waiting
      assert updated.current_step == HephaestusOban.Test.AsyncStep
    end
  end

  describe "perform/1 — resume from waiting" do
    test "resume step_result on waiting instance transitions to running and completes step", ctx do
      # Arrange — instance is waiting at AsyncStep
      instance = Instance.new(HephaestusOban.Test.AsyncWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      instance = %{instance | status: :waiting, current_step: HephaestusOban.Test.AsyncStep}
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      # Insert resume step_result
      step_ref = to_string(HephaestusOban.Test.AsyncStep)
      :ok = StepResults.insert(ctx.repo, instance.id, step_ref, "resumed", %{})

      # Act
      job = build_job(ctx.config_key, instance.id)
      assert :ok = AdvanceWorker.perform(job)

      # Assert — instance is no longer waiting, step completed
      {:ok, updated} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      refute updated.status == :waiting
      assert MapSet.member?(updated.completed_steps, HephaestusOban.Test.AsyncStep)
    end
  end

  describe "perform/1 — discarded step detection" do
    test "discarded ExecuteStepWorker causes workflow to be marked failed", ctx do
      # Arrange — instance running, simulate a discarded job in Oban
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Engine.advance(instance)
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      # Insert a discarded Oban job for this instance's step
      step_ref = to_string(HephaestusOban.Test.PassStep)
      insert_discarded_job(ctx.repo, instance.id, step_ref, ctx.config_key)

      # Act
      job = build_job(ctx.config_key, instance.id)
      assert :ok = AdvanceWorker.perform(job)

      # Assert — workflow marked failed
      {:ok, updated} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert updated.status == :failed
    end
  end

  # --- helpers ---

  defp build_job(config_key, instance_id) do
    %Oban.Job{
      args: %{"instance_id" => instance_id, "config_key" => config_key}
    }
  end

  defp assert_enqueued_execute_steps(active_steps, _instance_id) do
    # Verify via Oban.Testing that ExecuteStepWorker jobs were enqueued
    active_steps
    |> MapSet.to_list()
    |> Enum.each(fn step_module ->
      assert_enqueued(worker: HephaestusOban.ExecuteStepWorker,
                      args: %{"step_ref" => to_string(step_module)})
    end)
  end

  defp insert_discarded_job(repo, instance_id, step_ref, config_key) do
    # Insert an Oban job with state "discarded" to simulate exhausted retries
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
```

## Acceptance criteria

- [ ] All 6 test scenarios pass
- [ ] Advisory lock uses UUID binary extraction
- [ ] apply_step_results handles `__async__` sentinel correctly
- [ ] apply_step_results handles resume (waiting → running) correctly
- [ ] No regressions (`mix test`)
