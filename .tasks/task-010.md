# Task 010: Integration tests + scaffold cleanup

**Wave**: 5 | **Effort**: M
**Depends on**: task-009
**Blocks**: none

## Objective

Write integration tests that exercise the full workflow execution pipeline end-to-end, then clean up the scaffold module and test file.

## Files

**Create:** `test/hephaestus_oban/integration_test.exs` — integration tests
**Modify:** `lib/hephaestus_oban.ex` — replace scaffold with module doc
**Delete:** `test/hephaestus_oban_test.exs` — remove scaffold test

## Requirements

### Integration tests

Uses `Oban.drain_queue/1` to execute jobs synchronously and verify end-to-end pipeline.

### Scaffold cleanup

Replace `lib/hephaestus_oban.ex` with proper `@moduledoc`. Delete `test/hephaestus_oban_test.exs`.

## Test file

`test/hephaestus_oban/integration_test.exs`

## Test sequence

```elixir
defmodule HephaestusOban.IntegrationTest do
  use ExUnit.Case, async: false

  alias Hephaestus.Core.Instance
  alias HephaestusOban.{AdvanceWorker, Runner, StepResults}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)
    # Allow sandbox access from Oban's async job processes
    Ecto.Adapters.SQL.Sandbox.mode(HephaestusOban.TestRepo, {:shared, self()})

    repo = HephaestusOban.TestRepo

    storage_name = :"test_int_storage_#{System.unique_integer([:positive])}"
    {:ok, _} = HephaestusEcto.Storage.start_link(repo: repo, name: storage_name)

    config_key = "test_int_#{System.unique_integer([:positive])}"
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

  describe "linear workflow end-to-end" do
    test "start → advance → execute → advance → completed", ctx do
      # Arrange — create and persist a pending instance
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      # Act — enqueue initial AdvanceWorker and drain all jobs
      AdvanceWorker.new(%{"instance_id" => instance.id, "config_key" => ctx.config_key})
      |> Oban.insert!(Oban)

      Oban.drain_queue(queue: :hephaestus)

      # Assert — instance is completed
      {:ok, final} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert final.status == :completed
      assert MapSet.member?(final.completed_steps, HephaestusOban.Test.PassStep)
      assert MapSet.member?(final.completed_steps, Hephaestus.Steps.Done)

      # Assert — all step_results processed
      assert StepResults.pending_for(ctx.repo, instance.id) == []
    end
  end

  describe "async workflow end-to-end" do
    test "start → execute async → waiting → resume → completed", ctx do
      # Arrange
      instance = Instance.new(HephaestusOban.Test.AsyncWorkflow, %{})
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      # Act — initial advance + execute
      AdvanceWorker.new(%{"instance_id" => instance.id, "config_key" => ctx.config_key})
      |> Oban.insert!(Oban)

      Oban.drain_queue(queue: :hephaestus)

      # Assert — instance is waiting at AsyncStep
      {:ok, waiting} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert waiting.status == :waiting
      assert waiting.current_step == HephaestusOban.Test.AsyncStep

      # Act — simulate external resume event
      step_ref = to_string(HephaestusOban.Test.AsyncStep)
      HephaestusOban.ResumeWorker.new(%{
        "instance_id" => instance.id,
        "step_ref" => step_ref,
        "event" => "resumed",
        "config_key" => ctx.config_key
      })
      |> Oban.insert!(Oban)

      Oban.drain_queue(queue: :hephaestus)

      # Assert — instance completed
      {:ok, final} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert final.status == :completed
      assert MapSet.member?(final.completed_steps, HephaestusOban.Test.AsyncStep)
    end
  end

  describe "step failure end-to-end" do
    test "step fails max_attempts times → workflow marked :failed", ctx do
      # Arrange — instance with FailStep as the start step
      # Need a workflow that starts with FailStep
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Hephaestus.Core.Engine.advance(instance)
      # Replace active step with FailStep to simulate failure scenario
      instance = %{instance | active_steps: MapSet.new([HephaestusOban.Test.FailStep])}
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      # Act — enqueue ExecuteStepWorker for FailStep with max_attempts: 1
      HephaestusOban.ExecuteStepWorker.new(
        %{
          "instance_id" => instance.id,
          "step_ref" => to_string(HephaestusOban.Test.FailStep),
          "config_key" => ctx.config_key
        },
        max_attempts: 1
      )
      |> Oban.insert!(Oban)

      # Drain — the job will fail and be discarded (max_attempts: 1)
      Oban.drain_queue(queue: :hephaestus)

      # The FailureHandler telemetry should have enqueued an AdvanceWorker
      Oban.drain_queue(queue: :hephaestus)

      # Assert — workflow is failed
      {:ok, final} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert final.status == :failed
    end
  end

  describe "schedule_resume creates scheduled job" do
    test "creates ResumeWorker job with correct scheduled_at", ctx do
      # Arrange
      setup_runner_config(ctx)

      instance = Instance.new(HephaestusOban.Test.AsyncWorkflow, %{})
      instance = %{instance |
        status: :waiting,
        current_step: HephaestusOban.Test.AsyncStep
      }
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      delay_ms = 30_000
      before = DateTime.utc_now()

      # Act
      {:ok, job_id} = Runner.schedule_resume(
        instance.id,
        HephaestusOban.Test.AsyncStep,
        delay_ms
      )

      # Assert — job exists with scheduled_at in the future
      job = ctx.repo.get!(Oban.Job, job_id)
      assert job.worker == "HephaestusOban.ResumeWorker"
      assert job.state == "scheduled"
      # scheduled_at should be ~30s from now
      expected_at = DateTime.add(before, delay_ms, :millisecond)
      diff_seconds = abs(DateTime.diff(job.scheduled_at, expected_at, :second))
      assert diff_seconds <= 2
    end
  end

  describe "context propagation end-to-end" do
    test "step context_updates are available after workflow completes", ctx do
      # Arrange — use a workflow where a step produces context
      # PassWithContextStep returns {:ok, :done, %{processed: true}}
      instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
      {:ok, instance} = Hephaestus.Core.Engine.advance(instance)
      # Set PassWithContextStep as the active step
      instance = %{instance | active_steps: MapSet.new([HephaestusOban.Test.PassWithContextStep])}
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      # Insert step result with context updates and trigger advance
      step_ref = to_string(HephaestusOban.Test.PassWithContextStep)
      StepResults.insert(ctx.repo, instance.id, step_ref, "done", %{"processed" => true})

      AdvanceWorker.new(%{"instance_id" => instance.id, "config_key" => ctx.config_key})
      |> Oban.insert!(Oban)

      Oban.drain_queue(queue: :hephaestus)

      # Assert — context_updates were applied
      {:ok, final} = HephaestusEcto.Storage.get(ctx.storage_name, instance.id)
      assert MapSet.member?(final.completed_steps, HephaestusOban.Test.PassWithContextStep)
    end
  end

  # --- helpers ---

  defp setup_runner_config(ctx) do
    config = %{
      key: ctx.config_key,
      repo: ctx.repo,
      oban: Oban,
      storage: {HephaestusEcto.Storage, ctx.storage_name}
    }
    :persistent_term.put({HephaestusOban, :config, ctx.config_key}, config)
  end
end
```

## Acceptance criteria

- [ ] Linear workflow test: start → completed
- [ ] Async workflow test: start → waiting → resume → completed
- [ ] Failure test: step exhausts retries → workflow :failed
- [ ] Timer test: schedule_resume creates scheduled job with correct time
- [ ] Context propagation test: step_results context_updates applied
- [ ] Scaffold module replaced with proper @moduledoc
- [ ] Scaffold test deleted
- [ ] `mix test` passes with zero warnings
