defmodule HephaestusOban.StepResultsTest do
  use ExUnit.Case, async: false

  alias Hephaestus.Core.Instance
  alias HephaestusOban.StepResults

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)

    # Arrange — persist an instance so FK constraints are satisfied
    instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
    HephaestusEcto.Storage.start_link(repo: HephaestusOban.TestRepo, name: :test_sr_storage)
    HephaestusEcto.Storage.put(:test_sr_storage, instance)

    %{instance: instance, repo: HephaestusOban.TestRepo}
  end

  describe "insert/5 and pending_for/2" do
    test "inserts a step result and retrieves it as pending", %{instance: inst, repo: repo} do
      # Act
      :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{})

      # Assert
      pending = StepResults.pending_for(repo, inst.id)
      assert length(pending) == 1
      assert String.downcase(hd(pending).instance_id) == String.downcase(inst.id)
      assert hd(pending).step_ref == "Elixir.SomeStep"
      assert hd(pending).event == "done"
      assert hd(pending).processed == false
    end
  end

  describe "exists?/3" do
    test "returns true when unprocessed result exists for step", %{instance: inst, repo: repo} do
      # Arrange
      :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{})

      # Act
      result = StepResults.exists?(repo, inst.id, "Elixir.SomeStep")

      # Assert
      assert result == true
    end

    test "returns false when no result exists for step", %{instance: inst, repo: repo} do
      # Act
      result = StepResults.exists?(repo, inst.id, "Elixir.NonExistent")

      # Assert
      assert result == false
    end

    test "returns false after result is marked processed", %{instance: inst, repo: repo} do
      # Arrange
      :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{})
      pending = StepResults.pending_for(repo, inst.id)
      :ok = StepResults.mark_processed(repo, pending)

      # Act
      result = StepResults.exists?(repo, inst.id, "Elixir.SomeStep")

      # Assert
      assert result == false
    end
  end

  describe "insert/5 idempotency" do
    test "duplicate insert for same (instance_id, step_ref) is idempotent", %{instance: inst, repo: repo} do
      # Act
      :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{})
      :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{})

      # Assert — only one row exists
      pending = StepResults.pending_for(repo, inst.id)
      assert length(pending) == 1
    end
  end

  describe "mark_processed/2" do
    test "marks results as processed so they no longer appear in pending", %{instance: inst, repo: repo} do
      # Arrange
      :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{})
      pending = StepResults.pending_for(repo, inst.id)
      assert length(pending) == 1

      # Act
      :ok = StepResults.mark_processed(repo, pending)

      # Assert
      assert StepResults.pending_for(repo, inst.id) == []
    end
  end

  describe "pending_for/2 ordering" do
    test "returns results ordered by inserted_at ascending", %{instance: inst, repo: repo} do
      # Arrange — insert two results with a small time gap
      :ok = StepResults.insert(repo, inst.id, "Elixir.StepA", "done", %{})
      Process.sleep(10)
      :ok = StepResults.insert(repo, inst.id, "Elixir.StepB", "done", %{})

      # Act
      pending = StepResults.pending_for(repo, inst.id)

      # Assert
      assert Enum.map(pending, & &1.step_ref) == ["Elixir.StepA", "Elixir.StepB"]
    end
  end

  describe "insert/5 with context_updates" do
    test "stores context_updates map in the step result", %{instance: inst, repo: repo} do
      # Arrange
      context = %{"processed" => true, "count" => 42}

      # Act
      :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", context)

      # Assert
      [result] = StepResults.pending_for(repo, inst.id)
      assert result.context_updates == %{"processed" => true, "count" => 42}
    end
  end

  describe "insert/6 with workflow_version" do
    test "persists workflow_version on the step result", %{instance: inst, repo: repo} do
      :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{}, %{}, 3)

      [result] = StepResults.pending_for(repo, inst.id)
      assert result.workflow_version == 3
    end
  end
end
