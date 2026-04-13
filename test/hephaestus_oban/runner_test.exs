defmodule HephaestusOban.RunnerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: HephaestusOban.TestRepo

  alias Hephaestus.Core.Instance
  alias HephaestusOban.Runner

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)
    repo = HephaestusOban.TestRepo

    storage_name = :"test_runner_storage_#{System.unique_integer([:positive])}"
    :ignore = HephaestusEcto.Storage.start_link(repo: repo, name: storage_name)

    config_key = "test_runner_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :persistent_term.erase({HephaestusOban, :config, config_key})
      :telemetry.detach("hephaestus-step-discarded")
    end)

    %{repo: repo, storage_name: storage_name, config_key: config_key}
  end

  describe "start_link/1" do
    test "stores config in persistent_term and attaches FailureHandler", ctx do
      opts = [
        config_key: ctx.config_key,
        repo: ctx.repo,
        oban: Oban,
        storage: {HephaestusEcto.Storage, ctx.storage_name}
      ]

      assert :ignore = Runner.start_link(opts)

      config = :persistent_term.get({HephaestusOban, :config, ctx.config_key})
      assert config.repo == ctx.repo
      assert config.oban == Oban
      assert config.key == ctx.config_key
      assert config.storage == {HephaestusEcto.Storage, ctx.storage_name}

      handlers = :telemetry.list_handlers([:oban, :job, :stop])
      assert Enum.any?(handlers, &(&1.id == "hephaestus-step-discarded"))
    end
  end

  describe "start_instance/3" do
    test "persists new instance and enqueues AdvanceWorker with workflow + meta/tags", ctx do
      setup_runner_config(ctx)

      opts = [
        storage: {HephaestusEcto.Storage, ctx.storage_name},
        config_key: ctx.config_key,
        oban: Oban,
        id: "testoban::test#{System.unique_integer([:positive])}"
      ]

      assert {:ok, instance_id} =
               Runner.start_instance(HephaestusOban.Test.LinearWorkflow, %{data: "test"}, opts)

      assert {:ok, instance} = HephaestusEcto.Storage.get(ctx.storage_name, instance_id)
      assert instance.workflow == HephaestusOban.Test.LinearWorkflow
      assert instance.status == :pending
      assert instance.context.initial == %{data: "test"}

      assert_enqueued(
        worker: HephaestusOban.AdvanceWorker,
        args: %{"instance_id" => instance_id, "config_key" => ctx.config_key}
      )

      assert [job] = all_enqueued(worker: HephaestusOban.AdvanceWorker)
      assert job.args["workflow"] == "Elixir.HephaestusOban.Test.LinearWorkflow"
      assert "linear_workflow" in job.tags
      assert job.meta["heph_workflow"] == "linear_workflow"
      assert job.meta["instance_id"] == instance_id
    end

    test "creates instance with workflow_version from opts and includes it in job args", ctx do
      setup_runner_config(ctx)

      opts = [
        storage: {HephaestusEcto.Storage, ctx.storage_name},
        config_key: ctx.config_key,
        oban: Oban,
        id: "testoban::test#{System.unique_integer([:positive])}",
        workflow_version: 2
      ]

      assert {:ok, instance_id} =
               Runner.start_instance(HephaestusOban.Test.LinearWorkflow, %{}, opts)

      assert {:ok, instance} = HephaestusEcto.Storage.get(ctx.storage_name, instance_id)
      assert instance.workflow_version == 2

      assert [job] = all_enqueued(worker: HephaestusOban.AdvanceWorker)
      assert job.args["workflow_version"] == 2
    end

    test "defaults workflow_version to 1 when not provided in opts", ctx do
      setup_runner_config(ctx)

      opts = [
        storage: {HephaestusEcto.Storage, ctx.storage_name},
        config_key: ctx.config_key,
        oban: Oban,
        id: "testoban::test#{System.unique_integer([:positive])}"
      ]

      assert {:ok, instance_id} =
               Runner.start_instance(HephaestusOban.Test.LinearWorkflow, %{}, opts)

      assert {:ok, instance} = HephaestusEcto.Storage.get(ctx.storage_name, instance_id)
      assert instance.workflow_version == 1

      assert [job] = all_enqueued(worker: HephaestusOban.AdvanceWorker)
      assert job.args["workflow_version"] == 1
    end
  end

  describe "resume/2" do
    test "enqueues ResumeWorker with current_step, event, workflow + meta/tags", ctx do
      setup_runner_config(ctx)

      instance =
        Instance.new(
          HephaestusOban.Test.AsyncWorkflow,
          1,
          %{},
          "testoban::test#{System.unique_integer([:positive])}"
        )

      instance = %{
        instance
        | status: :waiting,
          current_step: HephaestusOban.Test.AsyncStep,
          active_steps: MapSet.new([HephaestusOban.Test.AsyncStep])
      }

      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)

      assert :ok = Runner.resume(instance.id, :resumed)

      assert_enqueued(
        worker: HephaestusOban.ResumeWorker,
        args: %{
          "instance_id" => instance.id,
          "step_ref" => to_string(HephaestusOban.Test.AsyncStep),
          "event" => "resumed",
          "config_key" => ctx.config_key
        }
      )

      assert [job] = all_enqueued(worker: HephaestusOban.ResumeWorker)
      assert job.args["workflow"] == "Elixir.HephaestusOban.Test.AsyncWorkflow"
      assert "async_workflow" in job.tags
      assert job.meta["heph_workflow"] == "async_workflow"
      assert job.meta["instance_id"] == instance.id
      assert job.meta["step"] == "async_step"
    end
  end

  describe "schedule_resume/3" do
    test "enqueues ResumeWorker with scheduled_at, workflow + meta/tags and returns job_id",
         ctx do
      setup_runner_config(ctx)

      instance =
        Instance.new(
          HephaestusOban.Test.AsyncWorkflow,
          1,
          %{},
          "testoban::test#{System.unique_integer([:positive])}"
        )

      instance = %{
        instance
        | status: :waiting,
          current_step: HephaestusOban.Test.AsyncStep,
          active_steps: MapSet.new([HephaestusOban.Test.AsyncStep])
      }

      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)

      delay_ms = 30_000

      assert {:ok, job_id} =
               Runner.schedule_resume(instance.id, HephaestusOban.Test.AsyncStep, delay_ms)

      assert is_integer(job_id)

      assert_enqueued(
        worker: HephaestusOban.ResumeWorker,
        args: %{
          "instance_id" => instance.id,
          "step_ref" => to_string(HephaestusOban.Test.AsyncStep),
          "event" => "timeout",
          "config_key" => ctx.config_key
        }
      )

      assert [job] = all_enqueued(worker: HephaestusOban.ResumeWorker)
      assert job.args["workflow"] == "Elixir.HephaestusOban.Test.AsyncWorkflow"
      assert "async_workflow" in job.tags
      assert job.meta["heph_workflow"] == "async_workflow"
      assert job.meta["instance_id"] == instance.id
      assert job.meta["step"] == "async_step"
    end

    test "scheduled_at is approximately delay_ms in the future", ctx do
      setup_runner_config(ctx)

      instance =
        Instance.new(
          HephaestusOban.Test.AsyncWorkflow,
          1,
          %{},
          "testoban::test#{System.unique_integer([:positive])}"
        )
      instance = %{instance | status: :waiting, current_step: HephaestusOban.Test.AsyncStep}
      :ok = HephaestusEcto.Storage.put(ctx.storage_name, instance)

      delay_ms = 60_000
      before = DateTime.utc_now()

      {:ok, job_id} = Runner.schedule_resume(instance.id, HephaestusOban.Test.AsyncStep, delay_ms)

      job = ctx.repo.get!(Oban.Job, job_id)
      expected_at = DateTime.add(before, delay_ms, :millisecond)
      diff_seconds = abs(DateTime.diff(job.scheduled_at, expected_at, :second))
      assert diff_seconds <= 2
    end
  end

  describe "child_spec/1" do
    test "returns temporary restart strategy" do
      spec = Runner.child_spec(config_key: "test", repo: nil, oban: nil, storage: nil)

      assert spec.restart == :temporary
    end
  end

  defp setup_runner_config(ctx) do
    :persistent_term.put(
      {HephaestusOban, :config, ctx.config_key},
      %{
        key: ctx.config_key,
        repo: ctx.repo,
        oban: Oban,
        storage: {HephaestusEcto.Storage, ctx.storage_name}
      }
    )
  end
end
