# Task 009: Runner behaviour implementation

**Wave**: 4 | **Effort**: M
**Depends on**: task-006, task-007, task-008
**Blocks**: task-010

## Objective

Implement the `HephaestusOban.Runner` module — the public API implementing `Hephaestus.Runtime.Runner` behaviour. Stores config in persistent_term, delegates to workers, and attaches the FailureHandler telemetry listener.

## Files

**Create:** `lib/hephaestus_oban/runner.ex` — behaviour implementation
**Create:** `test/hephaestus_oban/runner_test.exs` — unit tests
**Read:** `lib/hephaestus_oban/workers/advance_worker.ex` — enqueued by start_instance
**Read:** `lib/hephaestus_oban/workers/resume_worker.ex` — enqueued by resume/schedule_resume
**Read:** `lib/hephaestus_oban/failure_handler.ex` — attached during start_link

## Requirements

### Module structure

```elixir
defmodule HephaestusOban.Runner do
  @behaviour Hephaestus.Runtime.Runner
```

### start_link/1

Stores config in persistent_term and attaches FailureHandler. Returns `:ignore`.

### child_spec/1

Returns `:temporary` restart.

### Behaviour callbacks

- **start_instance/3**: creates Instance, persists via storage, enqueues AdvanceWorker, returns `{:ok, id}`
- **resume/2**: loads instance to get current_step, enqueues ResumeWorker with event
- **schedule_resume/3**: enqueues ResumeWorker with `scheduled_at`, returns `{:ok, job_id}`

## Test file

`test/hephaestus_oban/runner_test.exs`

## Test sequence

```elixir
defmodule HephaestusOban.RunnerTest do
  use ExUnit.Case, async: false

  alias Hephaestus.Core.Instance
  alias HephaestusOban.Runner

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)
    repo = HephaestusOban.TestRepo

    storage_name = :"test_runner_storage_#{System.unique_integer([:positive])}"
    {:ok, _} = HephaestusEcto.Storage.start_link(repo: repo, name: storage_name)

    config_key = "test_runner_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :persistent_term.erase({HephaestusOban, :config, config_key})
      :telemetry.detach("hephaestus-step-discarded")
    end)

    %{repo: repo, storage_name: storage_name, config_key: config_key}
  end

  describe "start_link/1" do
    test "stores config in persistent_term and attaches FailureHandler", ctx do
      # Arrange
      opts = [
        config_key: ctx.config_key,
        repo: ctx.repo,
        oban: Oban,
        storage: {HephaestusEcto.Storage, ctx.storage_name}
      ]

      # Act
      assert :ignore = Runner.start_link(opts)

      # Assert — config stored in persistent_term
      config = :persistent_term.get({HephaestusOban, :config, ctx.config_key})
      assert config.repo == ctx.repo
      assert config.oban == Oban
      assert config.key == ctx.config_key

      # Assert — telemetry handler attached (will raise if already attached)
      handlers = :telemetry.list_handlers([:oban, :job, :stop])
      assert Enum.any?(handlers, &(&1.id == "hephaestus-step-discarded"))
    end
  end

  describe "start_instance/3" do
    test "persists new instance and enqueues AdvanceWorker", ctx do
      # Arrange — set up Runner config
      setup_runner_config(ctx)

      opts = [
        storage: {HephaestusEcto.Storage, ctx.storage_name},
        config_key: ctx.config_key,
        oban: Oban
      ]

      # Act
      assert {:ok, instance_id} =
               Runner.start_instance(HephaestusOban.Test.LinearWorkflow, %{data: "test"}, opts)

      # Assert — instance persisted with correct workflow
      {:ok, instance} = HephaestusEcto.Storage.get(ctx.storage_name, instance_id)
      assert instance.workflow == HephaestusOban.Test.LinearWorkflow
      assert instance.status == :pending
      assert instance.context.initial == %{data: "test"}

      # Assert — AdvanceWorker enqueued
      assert_enqueued(worker: HephaestusOban.AdvanceWorker,
                      args: %{"instance_id" => instance_id,
                              "config_key" => ctx.config_key})
    end
  end

  describe "resume/2" do
    test "enqueues ResumeWorker with current_step and event", ctx do
      # Arrange — set up Runner config and a waiting instance
      setup_runner_config(ctx)

      instance = Instance.new(HephaestusOban.Test.AsyncWorkflow, %{})
      instance = %{instance |
        status: :waiting,
        current_step: HephaestusOban.Test.AsyncStep,
        active_steps: MapSet.new([HephaestusOban.Test.AsyncStep])
      }
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      # Act
      assert :ok = Runner.resume(instance.id, :resumed)

      # Assert — ResumeWorker enqueued with correct args
      assert_enqueued(worker: HephaestusOban.ResumeWorker,
                      args: %{
                        "instance_id" => instance.id,
                        "step_ref" => to_string(HephaestusOban.Test.AsyncStep),
                        "event" => "resumed",
                        "config_key" => ctx.config_key
                      })
    end
  end

  describe "schedule_resume/3" do
    test "enqueues ResumeWorker with scheduled_at and returns job_id", ctx do
      # Arrange
      setup_runner_config(ctx)

      instance = Instance.new(HephaestusOban.Test.AsyncWorkflow, %{})
      instance = %{instance |
        status: :waiting,
        current_step: HephaestusOban.Test.AsyncStep,
        active_steps: MapSet.new([HephaestusOban.Test.AsyncStep])
      }
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      delay_ms = 30_000

      # Act
      assert {:ok, job_id} =
               Runner.schedule_resume(instance.id, HephaestusOban.Test.AsyncStep, delay_ms)

      # Assert — job_id is an integer (Oban job ID)
      assert is_integer(job_id)

      # Assert — ResumeWorker enqueued with timeout event
      assert_enqueued(worker: HephaestusOban.ResumeWorker,
                      args: %{
                        "instance_id" => instance.id,
                        "step_ref" => to_string(HephaestusOban.Test.AsyncStep),
                        "event" => "timeout",
                        "config_key" => ctx.config_key
                      })
    end

    test "scheduled_at is approximately delay_ms in the future", ctx do
      # Arrange
      setup_runner_config(ctx)

      instance = Instance.new(HephaestusOban.Test.AsyncWorkflow, %{})
      instance = %{instance |
        status: :waiting,
        current_step: HephaestusOban.Test.AsyncStep
      }
      HephaestusEcto.Storage.put(ctx.storage_name, instance)

      delay_ms = 60_000
      before = DateTime.utc_now()

      # Act
      {:ok, job_id} = Runner.schedule_resume(instance.id, HephaestusOban.Test.AsyncStep, delay_ms)

      # Assert — scheduled_at is ~60s from now (within 2s tolerance)
      job = ctx.repo.get!(Oban.Job, job_id)
      expected_at = DateTime.add(before, delay_ms, :millisecond)
      diff_seconds = abs(DateTime.diff(job.scheduled_at, expected_at, :second))
      assert diff_seconds <= 2
    end
  end

  describe "child_spec/1" do
    test "returns temporary restart strategy" do
      # Act
      spec = Runner.child_spec(config_key: "test", repo: nil, oban: nil, storage: nil)

      # Assert
      assert spec.restart == :temporary
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

- [ ] All 6 tests pass
- [ ] start_link stores config and attaches FailureHandler
- [ ] child_spec returns `:temporary` restart
- [ ] All 3 behaviour callbacks work correctly
- [ ] No regressions (`mix test`)
