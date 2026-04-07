defmodule HephaestusOban.FailureHandlerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: HephaestusOban.TestRepo

  alias HephaestusOban.FailureHandler

  @execute_step_worker "HephaestusOban.ExecuteStepWorker"

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

    %{config_key: config_key}
  end

  describe "attach/0" do
    test "registers telemetry handler without error" do
      # Act
      result = FailureHandler.attach()

      # Assert
      assert result == :ok
    end
  end

  describe "handle_event/4 for discarded ExecuteStepWorker jobs" do
    test "AdvanceWorker created on discard has correct meta and tags", ctx do
      # Arrange
      instance_id = Ecto.UUID.generate()

      job = %Oban.Job{
        worker: @execute_step_worker,
        args: %{
          "instance_id" => instance_id,
          "step_ref" => to_string(HephaestusOban.Test.FailStep),
          "config_key" => ctx.config_key,
          "workflow" => to_string(HephaestusOban.Test.LinearWorkflow)
        },
        queue: "hephaestus"
      }

      # Act
      assert {:ok, %Oban.Job{worker: "HephaestusOban.AdvanceWorker"}} =
               FailureHandler.handle_event(
                 [:oban, :job, :stop],
                 %{duration: 100},
                 %{job: job, state: :discard},
                 nil
               )

      # Assert
      assert [advance_job] = all_enqueued(worker: HephaestusOban.AdvanceWorker)
      assert advance_job.args["workflow"] == to_string(HephaestusOban.Test.LinearWorkflow)
      assert advance_job.meta["heph_workflow"] == "linear_workflow"
      assert advance_job.meta["step"] == "fail_step"
      assert advance_job.meta["instance_id"] == instance_id
      assert "linear_workflow" in advance_job.tags
    end
  end

  describe "handle_event/4 for discarded non-ExecuteStepWorker jobs" do
    test "ignores discarded AdvanceWorker jobs", ctx do
      # Arrange
      instance_id = Ecto.UUID.generate()

      job = %Oban.Job{
        worker: "Elixir.HephaestusOban.AdvanceWorker",
        args: %{"instance_id" => instance_id, "config_key" => ctx.config_key},
        queue: "hephaestus"
      }

      # Act
      result =
        FailureHandler.handle_event(
          [:oban, :job, :stop],
          %{duration: 100},
          %{job: job, state: :discard},
          nil
        )

      # Assert
      assert result == :ok
      refute_enqueued(worker: HephaestusOban.AdvanceWorker, args: %{"instance_id" => instance_id})
    end
  end

  describe "handle_event/4 for non-discard states" do
    test "ignores successful job completions" do
      # Arrange
      job = %Oban.Job{
        worker: @execute_step_worker,
        args: %{"instance_id" => Ecto.UUID.generate(), "config_key" => "irrelevant"},
        queue: "hephaestus"
      }

      # Act
      result =
        FailureHandler.handle_event(
          [:oban, :job, :stop],
          %{duration: 100},
          %{job: job, state: :success},
          nil
        )

      # Assert
      assert result == :ok
    end

    test "ignores failure state before retries are exhausted" do
      # Arrange
      job = %Oban.Job{
        worker: @execute_step_worker,
        args: %{"instance_id" => Ecto.UUID.generate(), "config_key" => "irrelevant"},
        queue: "hephaestus"
      }

      # Act
      result =
        FailureHandler.handle_event(
          [:oban, :job, :stop],
          %{duration: 100},
          %{job: job, state: :failure},
          nil
        )

      # Assert
      assert result == :ok
    end
  end
end
