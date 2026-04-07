# Task 007: ResumeWorker — external events and durable timers

**Wave**: 3 | **Effort**: S
**Depends on**: task-005
**Blocks**: task-009

## Objective

Implement the ResumeWorker — an Oban worker that handles external events and durable timers. It writes a step_result with the resume event and enqueues an AdvanceWorker. Never touches the Instance directly.

## Files

**Create:** `lib/hephaestus_oban/workers/resume_worker.ex` — worker implementation
**Create:** `test/hephaestus_oban/workers/resume_worker_test.exs` — unit tests
**Read:** `lib/hephaestus_oban/workers/advance_worker.ex` — AdvanceWorker (enqueued after result)
**Read:** `lib/hephaestus_oban/step_results.ex` — StepResults CRUD

## Requirements

### Worker configuration

```elixir
use Oban.Worker, queue: :hephaestus, max_attempts: 3
```

### perform/1 flow

1. Resolve config from `job.args["config_key"]`
2. `insert_result_and_advance(config, instance_id, step_ref, event, %{})`
3. Return `:ok`

### Shared helper

`insert_result_and_advance/5` wraps `StepResults.insert` + `Oban.insert!(AdvanceWorker)` in `Repo.transaction`. Same pattern as ExecuteStepWorker — consider extracting to a shared module.

## Test file

`test/hephaestus_oban/workers/resume_worker_test.exs`

## Test sequence

```elixir
defmodule HephaestusOban.Workers.ResumeWorkerTest do
  use ExUnit.Case, async: false

  alias Hephaestus.Core.Instance
  alias HephaestusOban.{ResumeWorker, StepResults}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)
    repo = HephaestusOban.TestRepo

    storage_name = :"test_rw_storage_#{System.unique_integer([:positive])}"
    {:ok, _} = HephaestusEcto.Storage.start_link(repo: repo, name: storage_name)

    config_key = "test_rw_#{System.unique_integer([:positive])}"
    config = %{
      key: config_key,
      repo: repo,
      oban: Oban,
      storage: {HephaestusEcto.Storage, storage_name}
    }
    :persistent_term.put({HephaestusOban, :config, config_key}, config)

    # Persist a waiting instance
    instance = Instance.new(HephaestusOban.Test.AsyncWorkflow, %{})
    instance = %{instance |
      status: :waiting,
      current_step: HephaestusOban.Test.AsyncStep,
      active_steps: MapSet.new([HephaestusOban.Test.AsyncStep])
    }
    HephaestusEcto.Storage.put(storage_name, instance)

    on_exit(fn -> :persistent_term.erase({HephaestusOban, :config, config_key}) end)

    %{repo: repo, config: config, config_key: config_key,
      storage_name: storage_name, instance: instance}
  end

  describe "perform/1 — resume event" do
    test "inserts step_result with event and enqueues AdvanceWorker", ctx do
      # Arrange
      step_ref = to_string(HephaestusOban.Test.AsyncStep)

      # Act
      job = build_job(ctx.config_key, ctx.instance.id, step_ref, "resumed")
      assert :ok = ResumeWorker.perform(job)

      # Assert — step_result inserted with resume event
      [result] = StepResults.pending_for(ctx.repo, ctx.instance.id)
      assert result.step_ref == step_ref
      assert result.event == "resumed"
      assert result.context_updates == %{}

      # Assert — AdvanceWorker enqueued
      assert_enqueued(worker: HephaestusOban.AdvanceWorker,
                      args: %{"instance_id" => ctx.instance.id})
    end
  end

  describe "perform/1 — does not modify Instance" do
    test "instance status remains unchanged after ResumeWorker runs", ctx do
      # Arrange
      step_ref = to_string(HephaestusOban.Test.AsyncStep)

      # Act
      job = build_job(ctx.config_key, ctx.instance.id, step_ref, "resumed")
      assert :ok = ResumeWorker.perform(job)

      # Assert — instance is still waiting (only AdvanceWorker mutates)
      {:ok, instance} = HephaestusEcto.Storage.get(ctx.storage_name, ctx.instance.id)
      assert instance.status == :waiting
      assert instance.current_step == HephaestusOban.Test.AsyncStep
    end
  end

  describe "perform/1 — atomicity" do
    test "step_result insert and AdvanceWorker enqueue are in same transaction", ctx do
      # Arrange
      step_ref = to_string(HephaestusOban.Test.AsyncStep)

      # Act
      job = build_job(ctx.config_key, ctx.instance.id, step_ref, "resumed")
      assert :ok = ResumeWorker.perform(job)

      # Assert — both step_result exists and AdvanceWorker enqueued
      assert length(StepResults.pending_for(ctx.repo, ctx.instance.id)) == 1
      assert_enqueued(worker: HephaestusOban.AdvanceWorker,
                      args: %{"instance_id" => ctx.instance.id})
    end
  end

  describe "perform/1 — timeout event from durable timer" do
    test "handles timeout event from scheduled resume", ctx do
      # Arrange
      step_ref = to_string(HephaestusOban.Test.AsyncStep)

      # Act — event is "timeout" from schedule_resume
      job = build_job(ctx.config_key, ctx.instance.id, step_ref, "timeout")
      assert :ok = ResumeWorker.perform(job)

      # Assert — step_result with timeout event
      [result] = StepResults.pending_for(ctx.repo, ctx.instance.id)
      assert result.event == "timeout"
    end
  end

  # --- helpers ---

  defp build_job(config_key, instance_id, step_ref, event) do
    %Oban.Job{
      args: %{
        "instance_id" => instance_id,
        "step_ref" => step_ref,
        "event" => event,
        "config_key" => config_key
      }
    }
  end
end
```

## Acceptance criteria

- [ ] All 4 tests pass
- [ ] Never writes to Instance/storage directly
- [ ] Atomicity confirmed (step_result + AdvanceWorker in transaction)
- [ ] No regressions (`mix test`)
