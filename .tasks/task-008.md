# Task 008: FailureHandler — telemetry listener for discarded jobs

**Wave**: 3 | **Effort**: S
**Depends on**: task-005
**Blocks**: task-009

## Objective

Implement the FailureHandler — a telemetry listener that detects when an ExecuteStepWorker job is discarded (exhausted all retries) and enqueues an AdvanceWorker so it can detect the failure and mark the workflow as `:failed`.

## Files

**Create:** `lib/hephaestus_oban/failure_handler.ex` — telemetry handler
**Create:** `test/hephaestus_oban/failure_handler_test.exs` — unit tests

## Requirements

### Module structure

```elixir
defmodule HephaestusOban.FailureHandler do
  @moduledoc false

  def attach do
    :telemetry.attach(
      "hephaestus-step-discarded",
      [:oban, :job, :stop],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event([:oban, :job, :stop], _measure, %{job: job, state: :discard}, _config) do
    if job.worker == "HephaestusOban.ExecuteStepWorker" do
      %{"instance_id" => instance_id, "config_key" => config_key} = job.args
      config = :persistent_term.get({HephaestusOban, :config, config_key})

      HephaestusOban.AdvanceWorker.new(%{
        "instance_id" => instance_id,
        "config_key" => config_key
      })
      |> Oban.insert(config.oban)
    end
  end

  def handle_event(_event, _measure, _meta, _config), do: :ok
end
```

## Test file

`test/hephaestus_oban/failure_handler_test.exs`

## Test sequence

```elixir
defmodule HephaestusOban.FailureHandlerTest do
  use ExUnit.Case, async: false

  alias HephaestusOban.FailureHandler

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)

    config_key = "test_fh_#{System.unique_integer([:positive])}"
    config = %{
      key: config_key,
      repo: HephaestusOban.TestRepo,
      oban: Oban,
      storage: nil
    }
    :persistent_term.put({HephaestusOban, :config, config_key}, config)

    on_exit(fn ->
      :persistent_term.erase({HephaestusOban, :config, config_key})
      :telemetry.detach("hephaestus-step-discarded")
    end)

    %{config_key: config_key, config: config}
  end

  describe "attach/0" do
    test "registers telemetry handler without error" do
      # Act & Assert — no crash
      assert :ok = FailureHandler.attach()
    end
  end

  describe "handle_event/4 — ExecuteStepWorker discard" do
    test "enqueues AdvanceWorker when ExecuteStepWorker is discarded", ctx do
      # Arrange
      instance_id = Ecto.UUID.generate()
      job = %Oban.Job{
        worker: "HephaestusOban.ExecuteStepWorker",
        args: %{
          "instance_id" => instance_id,
          "step_ref" => "Elixir.SomeStep",
          "config_key" => ctx.config_key
        },
        queue: "hephaestus"
      }

      # Act
      FailureHandler.handle_event(
        [:oban, :job, :stop],
        %{duration: 100},
        %{job: job, state: :discard},
        nil
      )

      # Assert — AdvanceWorker enqueued for this instance
      assert_enqueued(worker: HephaestusOban.AdvanceWorker,
                      args: %{"instance_id" => instance_id,
                              "config_key" => ctx.config_key})
    end
  end

  describe "handle_event/4 — non-ExecuteStepWorker discard" do
    test "ignores discarded AdvanceWorker jobs", ctx do
      # Arrange
      instance_id = Ecto.UUID.generate()
      job = %Oban.Job{
        worker: "HephaestusOban.AdvanceWorker",
        args: %{
          "instance_id" => instance_id,
          "config_key" => ctx.config_key
        },
        queue: "hephaestus"
      }

      # Act
      result = FailureHandler.handle_event(
        [:oban, :job, :stop],
        %{duration: 100},
        %{job: job, state: :discard},
        nil
      )

      # Assert — no AdvanceWorker enqueued (returns nil, not {:ok, job})
      assert result == nil

      # Assert — no jobs enqueued
      refute_enqueued(worker: HephaestusOban.AdvanceWorker,
                      args: %{"instance_id" => instance_id})
    end
  end

  describe "handle_event/4 — non-discard states" do
    test "ignores successful job completions" do
      # Arrange
      job = %Oban.Job{
        worker: "HephaestusOban.ExecuteStepWorker",
        args: %{"instance_id" => Ecto.UUID.generate(), "config_key" => "irrelevant"},
        queue: "hephaestus"
      }

      # Act
      result = FailureHandler.handle_event(
        [:oban, :job, :stop],
        %{duration: 100},
        %{job: job, state: :success},
        nil
      )

      # Assert — catch-all returns :ok
      assert result == :ok
    end

    test "ignores failure state (not discarded yet, will be retried)" do
      # Arrange
      job = %Oban.Job{
        worker: "HephaestusOban.ExecuteStepWorker",
        args: %{"instance_id" => Ecto.UUID.generate(), "config_key" => "irrelevant"},
        queue: "hephaestus"
      }

      # Act
      result = FailureHandler.handle_event(
        [:oban, :job, :stop],
        %{duration: 100},
        %{job: job, state: :failure},
        nil
      )

      # Assert — catch-all returns :ok
      assert result == :ok
    end
  end
end
```

## Acceptance criteria

- [ ] All 5 tests pass
- [ ] Only reacts to ExecuteStepWorker discards
- [ ] Ignores other workers and non-discard states
- [ ] No regressions (`mix test`)
