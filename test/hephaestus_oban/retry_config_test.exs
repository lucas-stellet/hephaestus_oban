defmodule HephaestusOban.RetryConfigTest do
  use ExUnit.Case, async: true

  alias HephaestusOban.RetryConfig

  # --- inline test modules ---

  defmodule StepWithRetry do
    @behaviour Hephaestus.Steps.Step
    def events, do: [:done]
    def execute(_, _, _), do: {:ok, :done}
    def retry_config, do: %{max_attempts: 10, backoff: :linear, max_backoff: 120_000}
  end

  defmodule StepWithoutRetry do
    @behaviour Hephaestus.Steps.Step
    def events, do: [:done]
    def execute(_, _, _), do: {:ok, :done}
  end

  defmodule WorkflowWithRetry do
    def default_retry_config, do: %{max_attempts: 3, backoff: :exponential, max_backoff: 30_000}
  end

  defmodule WorkflowWithoutRetry do
  end

  # --- tests ordered: happy path -> variations -> boundaries ---

  describe "resolve/2" do
    test "returns step-level config when step exports retry_config/0" do
      # Arrange
      step = StepWithRetry
      workflow = WorkflowWithRetry

      # Act
      config = RetryConfig.resolve(step, workflow)

      # Assert
      assert config == %{max_attempts: 10, backoff: :linear, max_backoff: 120_000}
    end

    test "returns workflow-level config when step has no retry_config/0" do
      # Arrange
      step = StepWithoutRetry
      workflow = WorkflowWithRetry

      # Act
      config = RetryConfig.resolve(step, workflow)

      # Assert
      assert config == %{max_attempts: 3, backoff: :exponential, max_backoff: 30_000}
    end

    test "returns default config when neither step nor workflow define config" do
      # Arrange
      step = StepWithoutRetry
      workflow = WorkflowWithoutRetry

      # Act
      config = RetryConfig.resolve(step, workflow)

      # Assert
      assert config == %{max_attempts: 5, backoff: :exponential, max_backoff: 60_000}
    end

    test "step-level config takes priority over workflow-level config" do
      # Arrange — both step and workflow define config
      step = StepWithRetry
      workflow = WorkflowWithRetry

      # Act
      config = RetryConfig.resolve(step, workflow)

      # Assert — step config wins
      assert config.max_attempts == 10
      refute config.max_attempts == 3
    end
  end

  describe "default/0" do
    test "returns the default retry configuration map" do
      # Act
      config = RetryConfig.default()

      # Assert
      assert config == %{max_attempts: 5, backoff: :exponential, max_backoff: 60_000}
    end
  end
end
