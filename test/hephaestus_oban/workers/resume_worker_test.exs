defmodule HephaestusOban.Workers.ResumeWorkerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: HephaestusOban.TestRepo

  alias Hephaestus.Core.Instance
  alias HephaestusOban.{ResumeWorker, StepResults}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)
    repo = HephaestusOban.TestRepo

    storage_name = :"test_rw_storage_#{System.unique_integer([:positive])}"
    :ignore = HephaestusEcto.Storage.start_link(repo: repo, name: storage_name)

    config_key = "test_rw_#{System.unique_integer([:positive])}"

    config = %{
      key: config_key,
      repo: repo,
      oban: Oban,
      storage: {HephaestusEcto.Storage, storage_name}
    }

    :persistent_term.put({HephaestusOban, :config, config_key}, config)

    instance = Instance.new(HephaestusOban.Test.AsyncWorkflow, %{})

    instance = %{
      instance
      | status: :waiting,
        current_step: HephaestusOban.Test.AsyncStep,
        active_steps: MapSet.new([HephaestusOban.Test.AsyncStep])
    }

    :ok = HephaestusEcto.Storage.put(storage_name, instance)

    on_exit(fn ->
      :persistent_term.erase({HephaestusOban, :config, config_key})
    end)

    %{
      repo: repo,
      config: config,
      config_key: config_key,
      storage_name: storage_name,
      instance: instance
    }
  end

  describe "perform/1 — resume event" do
    test "inserts step_result with event and enqueues AdvanceWorker", ctx do
      step_ref = to_string(HephaestusOban.Test.AsyncStep)

      job = resume_job(ctx.config_key, ctx.instance.id, step_ref, "resumed", to_string(HephaestusOban.Test.AsyncWorkflow))
      assert :ok = ResumeWorker.perform(job)

      [result] = StepResults.pending_for(ctx.repo, ctx.instance.id)
      assert result.step_ref == step_ref
      assert result.event == "resumed"
      assert result.context_updates == %{}
      assert result.workflow_version == 3

      assert [advance_job] = all_enqueued(worker: HephaestusOban.AdvanceWorker)
      assert advance_job.args["workflow"] == to_string(HephaestusOban.Test.AsyncWorkflow)
      assert advance_job.args["workflow_version"] == 3
      assert advance_job.meta["heph_workflow"] == "async_workflow"
      assert advance_job.meta["step"] == "async_step"
      assert "async_workflow" in advance_job.tags
    end
  end

  describe "perform/1 — does not modify Instance" do
    test "instance status remains unchanged after ResumeWorker runs", ctx do
      step_ref = to_string(HephaestusOban.Test.AsyncStep)

      job = resume_job(ctx.config_key, ctx.instance.id, step_ref, "resumed", to_string(HephaestusOban.Test.AsyncWorkflow))
      assert :ok = ResumeWorker.perform(job)

      {:ok, instance} = HephaestusEcto.Storage.get(ctx.storage_name, ctx.instance.id)
      assert instance.status == :waiting
      assert instance.current_step == HephaestusOban.Test.AsyncStep
    end
  end

  describe "perform/1 — atomicity" do
    test "step_result insert and AdvanceWorker enqueue are in same transaction", ctx do
      step_ref = to_string(HephaestusOban.Test.AsyncStep)

      job = resume_job(ctx.config_key, ctx.instance.id, step_ref, "resumed", to_string(HephaestusOban.Test.AsyncWorkflow))
      assert :ok = ResumeWorker.perform(job)

      assert length(StepResults.pending_for(ctx.repo, ctx.instance.id)) == 1

      assert_enqueued(
        worker: HephaestusOban.AdvanceWorker,
        args: %{"instance_id" => ctx.instance.id, "config_key" => ctx.config_key}
      )
    end
  end

  describe "perform/1 — timeout event from durable timer" do
    test "handles timeout event from scheduled resume", ctx do
      step_ref = to_string(HephaestusOban.Test.AsyncStep)

      job = resume_job(ctx.config_key, ctx.instance.id, step_ref, "timeout", to_string(HephaestusOban.Test.AsyncWorkflow))
      assert :ok = ResumeWorker.perform(job)

      [result] = StepResults.pending_for(ctx.repo, ctx.instance.id)
      assert result.event == "timeout"
    end
  end

  defp resume_job(config_key, instance_id, step_ref, event, workflow) do
    %Oban.Job{
      args: %{
        "instance_id" => instance_id,
        "step_ref" => step_ref,
        "event" => event,
        "config_key" => config_key,
        "workflow" => workflow,
        "workflow_version" => 3
      }
    }
  end
end
