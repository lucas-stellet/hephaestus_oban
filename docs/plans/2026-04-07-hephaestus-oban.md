# hephaestus_oban Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement an Oban-based runner adapter for hephaestus_core where each workflow step becomes an Oban job with retry/backoff, persisted via hephaestus_ecto.

**Architecture:** 3 Oban workers (AdvanceWorker, ExecuteStepWorker, ResumeWorker) + step_results auxiliary table. AdvanceWorker is the single Instance writer, serialized via Oban unique + PostgreSQL advisory lock. step_results table enables zero-contention fan-out.

**Tech Stack:** Elixir, Oban >= 2.14, hephaestus_ecto, Ecto, PostgreSQL

**Spec:** `docs/design-spec.md`

**Prerequisite:** hephaestus_ecto must be fully implemented and its migration run before starting this plan.

---

## Task 0: Project setup — dependencies and config

**Files:**
- Modify: `mix.exs`
- Modify: `lib/hephaestus_oban/application.ex`
- Create: `config/config.exs`
- Create: `config/test.exs`

- [ ] **Step 1: Update mix.exs**

```elixir
defmodule HephaestusOban.MixProject do
  use Mix.Project

  def project do
    [
      app: :hephaestus_oban,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {HephaestusOban.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:hephaestus, path: "../hephaestus_core"},
      {:hephaestus_ecto, path: "../hephaestus_ecto"},
      {:oban, "~> 2.14"},
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"}
    ]
  end

  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
    ]
  end
end
```

- [ ] **Step 2: Create config files**

`config/config.exs`:
```elixir
import Config
import_config "#{config_env()}.exs"
```

`config/test.exs`:
```elixir
import Config

config :hephaestus_oban, HephaestusOban.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "hephaestus_oban_test",
  pool: Ecto.Adapters.SQL.Sandbox

config :hephaestus_oban, Oban,
  repo: HephaestusOban.TestRepo,
  queues: false,
  testing: :manual
```

- [ ] **Step 3: Create test Repo and test support files**

`test/support/test_repo.ex`:
```elixir
defmodule HephaestusOban.TestRepo do
  use Ecto.Repo, otp_app: :hephaestus_oban, adapter: Ecto.Adapters.Postgres
end
```

`test/support/test_steps.ex`:
```elixir
defmodule HephaestusOban.Test.PassStep do
  @behaviour Hephaestus.Steps.Step
  @impl true
  def events, do: [:done]
  @impl true
  def execute(_instance, _config, _context), do: {:ok, :done}
end

defmodule HephaestusOban.Test.AsyncStep do
  @behaviour Hephaestus.Steps.Step
  @impl true
  def events, do: [:timeout, :resumed]
  @impl true
  def execute(_instance, _config, _context), do: {:async}
end

defmodule HephaestusOban.Test.FailStep do
  @behaviour Hephaestus.Steps.Step
  @impl true
  def events, do: [:done]
  @impl true
  def execute(_instance, _config, _context), do: {:error, :forced_failure}
end

defmodule HephaestusOban.Test.PassWithContextStep do
  @behaviour Hephaestus.Steps.Step
  @impl true
  def events, do: [:done]
  @impl true
  def execute(_instance, _config, _context), do: {:ok, :done, %{processed: true}}
end
```

`test/support/test_workflows.ex`:
```elixir
defmodule HephaestusOban.Test.LinearWorkflow do
  use Hephaestus.Workflow

  def start, do: HephaestusOban.Test.PassStep

  def transit(HephaestusOban.Test.PassStep, :done, _ctx), do: Hephaestus.Steps.Done
end

defmodule HephaestusOban.Test.AsyncWorkflow do
  use Hephaestus.Workflow

  def start, do: HephaestusOban.Test.AsyncStep

  def transit(HephaestusOban.Test.AsyncStep, :resumed, _ctx), do: Hephaestus.Steps.Done
end
```

- [ ] **Step 4: Update application.ex — empty supervision tree (library package)**

Library packages should not call `Mix.env()` at runtime (crashes in releases). The test Repo and Oban are started from `test_helper.exs`.

```elixir
defmodule HephaestusOban.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: HephaestusOban.Supervisor)
  end
end
```

- [ ] **Step 5: Create test migrations**

Create `priv/repo/migrations/20260407000000_create_workflow_instances.exs` (calls HephaestusEcto.Migration).
Create `priv/repo/migrations/20260407000001_create_oban_jobs.exs` (calls Oban.Migration).
Create `priv/repo/migrations/20260407000002_create_step_results.exs` (see Task 1).

- [ ] **Step 6: Update test_helper.exs — start Repo and Oban here**

```elixir
{:ok, _} = HephaestusOban.TestRepo.start_link()
{:ok, _} = Oban.start_link(Application.fetch_env!(:hephaestus_oban, Oban))
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(HephaestusOban.TestRepo, :manual)
```

- [ ] **Step 7: Verify deps fetch and compile**

Run: `mix deps.get && mix compile`
Expected: no errors

- [ ] **Step 8: Commit**

```bash
git add mix.exs lib/ config/ test/support/ test/test_helper.exs priv/
git commit -m "feat: project setup with oban, ecto, test support"
```

## Task 1: Migration and step_results schema

**Files:**
- Create: `lib/hephaestus_oban/migration.ex`
- Create: `lib/hephaestus_oban/schema/step_result.ex`
- Create: `lib/hephaestus_oban/step_results.ex`
- Create: `lib/mix/tasks/hephaestus_oban.gen.migration.ex`

- [ ] **Step 1: Create migration module**

`lib/hephaestus_oban/migration.ex`:
```elixir
defmodule HephaestusOban.Migration do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:hephaestus_step_results, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :instance_id, references(:workflow_instances, type: :uuid, on_delete: :delete_all), null: false
      add :step_ref, :string, null: false
      add :event, :string, null: false
      add :context_updates, :map, null: false, default: %{}
      add :processed, :boolean, null: false, default: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:hephaestus_step_results, [:instance_id], where: "NOT processed", name: :idx_step_results_pending)
    create unique_index(:hephaestus_step_results, [:instance_id, :step_ref], where: "NOT processed", name: :idx_step_results_unique)
  end

  def down do
    drop table(:hephaestus_step_results)
  end
end
```

- [ ] **Step 2: Create schema**

`lib/hephaestus_oban/schema/step_result.ex`:
```elixir
defmodule HephaestusOban.Schema.StepResult do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "hephaestus_step_results" do
    field :instance_id, :binary_id
    field :step_ref, :string
    field :event, :string
    field :context_updates, :map, default: %{}
    field :processed, :boolean, default: false
    field :inserted_at, :utc_datetime_usec
  end

  def changeset(result \\ %__MODULE__{}, attrs) do
    result
    |> cast(attrs, [:instance_id, :step_ref, :event, :context_updates])
    |> validate_required([:instance_id, :step_ref, :event])
  end
end
```

- [ ] **Step 3: Create StepResults CRUD module**

`lib/hephaestus_oban/step_results.ex`:
```elixir
defmodule HephaestusOban.StepResults do
  @moduledoc false
  import Ecto.Query
  alias HephaestusOban.Schema.StepResult

  def insert(repo, instance_id, step_ref, event, context_updates) do
    attrs = %{
      instance_id: instance_id,
      step_ref: step_ref,
      event: event,
      context_updates: context_updates
    }

    StepResult.changeset(attrs)
    |> repo.insert(on_conflict: :nothing, conflict_target: {:unsafe_fragment, ~s|(instance_id, step_ref) WHERE NOT processed|})
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> raise Ecto.InvalidChangesetError, changeset: changeset, action: :insert
    end

    :ok
  end

  def exists?(repo, instance_id, step_ref) do
    repo.exists?(
      from(r in StepResult,
        where: r.instance_id == ^instance_id and r.step_ref == ^step_ref and not r.processed)
    )
  end

  def pending_for(repo, instance_id) do
    repo.all(
      from(r in StepResult,
        where: r.instance_id == ^instance_id and not r.processed,
        order_by: [asc: r.inserted_at])
    )
  end

  def mark_processed(repo, results) do
    ids = Enum.map(results, & &1.id)
    from(r in StepResult, where: r.id in ^ids)
    |> repo.update_all(set: [processed: true])
    :ok
  end
end
```

- [ ] **Step 4: Create mix task (same pattern as hephaestus_ecto)**

`lib/mix/tasks/hephaestus_oban.gen.migration.ex` — generates migration that calls `HephaestusOban.Migration.up/down`.

- [ ] **Step 5: Verify migration runs**

Run: `mix ecto.create && mix ecto.migrate`
Expected: tables created

- [ ] **Step 6: Commit**

```bash
git add lib/hephaestus_oban/migration.ex lib/hephaestus_oban/schema/ lib/hephaestus_oban/step_results.ex lib/mix/ priv/
git commit -m "feat: step_results table, schema, CRUD module, migration generator"
```

## Task 2: StepResults unit tests

**Files:**
- Create: `test/hephaestus_oban/step_results_test.exs`

- [ ] **Step 1: Write tests**

```elixir
defmodule HephaestusOban.StepResultsTest do
  use ExUnit.Case

  alias Hephaestus.Core.Instance
  alias HephaestusOban.StepResults

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)

    instance = Instance.new(HephaestusOban.Test.LinearWorkflow, %{})
    HephaestusEcto.Storage.start_link(repo: HephaestusOban.TestRepo, name: :test_storage)
    HephaestusEcto.Storage.put(:test_storage, instance)

    %{instance: instance, repo: HephaestusOban.TestRepo}
  end

  test "insert and pending_for", %{instance: inst, repo: repo} do
    :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{})
    pending = StepResults.pending_for(repo, inst.id)
    assert length(pending) == 1
    assert hd(pending).event == "done"
  end

  test "exists? returns true for unprocessed", %{instance: inst, repo: repo} do
    :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{})
    assert StepResults.exists?(repo, inst.id, "Elixir.SomeStep")
  end

  test "duplicate insert is idempotent (ON CONFLICT DO NOTHING)", %{instance: inst, repo: repo} do
    :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{})
    :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{})
    pending = StepResults.pending_for(repo, inst.id)
    assert length(pending) == 1
  end

  test "mark_processed removes from pending", %{instance: inst, repo: repo} do
    :ok = StepResults.insert(repo, inst.id, "Elixir.SomeStep", "done", %{})
    pending = StepResults.pending_for(repo, inst.id)
    :ok = StepResults.mark_processed(repo, pending)
    assert StepResults.pending_for(repo, inst.id) == []
  end

  test "pending_for returns in inserted_at order", %{instance: inst, repo: repo} do
    :ok = StepResults.insert(repo, inst.id, "Elixir.StepA", "done", %{})
    Process.sleep(10)
    :ok = StepResults.insert(repo, inst.id, "Elixir.StepB", "done", %{})
    pending = StepResults.pending_for(repo, inst.id)
    assert Enum.map(pending, & &1.step_ref) == ["Elixir.StepA", "Elixir.StepB"]
  end
end
```

- [ ] **Step 2: Run tests**

Run: `mix test test/hephaestus_oban/step_results_test.exs -v`
Expected: all pass

- [ ] **Step 3: Commit**

```bash
git add test/hephaestus_oban/step_results_test.exs
git commit -m "test: add StepResults unit tests"
```

## Task 3: RetryConfig resolution module

**Files:**
- Create: `lib/hephaestus_oban/retry_config.ex`
- Create: `test/hephaestus_oban/retry_config_test.exs`

- [ ] **Step 1: Write failing tests**

Tests for the 4-level resolution: step -> workflow -> default -> oban.

- [ ] **Step 2: Implement module**

`lib/hephaestus_oban/retry_config.ex`:
```elixir
defmodule HephaestusOban.RetryConfig do
  @moduledoc false

  @default %{max_attempts: 5, backoff: :exponential, max_backoff: 60_000}

  def resolve(step_module, workflow_module) do
    cond do
      function_exported?(step_module, :retry_config, 0) ->
        step_module.retry_config()

      function_exported?(workflow_module, :default_retry_config, 0) ->
        workflow_module.default_retry_config()

      true ->
        @default
    end
  end

  def default, do: @default
end
```

- [ ] **Step 3: Run tests**

Run: `mix test test/hephaestus_oban/retry_config_test.exs -v`
Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add lib/hephaestus_oban/retry_config.ex test/hephaestus_oban/retry_config_test.exs
git commit -m "feat: add RetryConfig resolution module"
```

## Task 4: AdvanceWorker

**Files:**
- Create: `lib/hephaestus_oban/workers/advance_worker.ex`
- Create: `test/hephaestus_oban/workers/advance_worker_test.exs`

- [ ] **Step 1: Write failing tests**

Tests covering:
- Advance pending instance -> running with active steps -> enqueues ExecuteStepWorkers
- Apply step_results -> complete_step -> activate_transitions -> persist
- Instance completed -> no more jobs enqueued
- Instance waiting (__async__ sentinel) -> sets :waiting status
- Resume step_result on :waiting instance -> transitions to :running
- Discarded step detection -> marks workflow :failed

- [ ] **Step 2: Implement AdvanceWorker**

Implement per spec: Oban unique, advisory lock via UUID 64-bit, Repo.transaction, apply_step_results with __async__ sentinel handling, detect_discarded_steps outside transaction.

Key implementation points from spec:
- `<<lock_key::signed-integer-64, _rest::binary>> = Ecto.UUID.dump!(instance_id)`
- Transaction returns `{:continue, instance}` or `{:failed, instance}`
- Failure handling outside transaction
- **Resume handling:** When processing a non-`__async__` step_result and `instance.status == :waiting`, transition to `:running` before calling `Engine.complete_step`:
  ```elixir
  instance = if instance.status == :waiting, do: %{instance | status: :running, current_step: nil}, else: instance
  ```

- [ ] **Step 3: Run tests**

Run: `mix test test/hephaestus_oban/workers/advance_worker_test.exs -v`
Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add lib/hephaestus_oban/workers/advance_worker.ex test/hephaestus_oban/workers/advance_worker_test.exs
git commit -m "feat: implement AdvanceWorker — single Instance writer with advisory lock"
```

## Task 5: ExecuteStepWorker

**Files:**
- Create: `lib/hephaestus_oban/workers/execute_step_worker.ex`
- Create: `test/hephaestus_oban/workers/execute_step_worker_test.exs`

- [ ] **Step 1: Write failing tests**

Tests covering:
- Executes step, inserts step_result, enqueues AdvanceWorker atomically
- {:async} -> inserts __async__ sentinel step_result
- {:error, reason} -> returns error for Oban retry
- Idempotency: existing step_result -> skips execution
- Unique constraint: same (instance_id, step_ref)

- [ ] **Step 2: Implement ExecuteStepWorker**

Key points from spec:
- Unique per `[:instance_id, :step_ref]`
- Check `StepResults.exists?` before executing
- `insert_result_and_advance` wraps in Repo.transaction with Oban.insert/3

- [ ] **Step 3: Run tests**

Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add lib/hephaestus_oban/workers/execute_step_worker.ex test/hephaestus_oban/workers/execute_step_worker_test.exs
git commit -m "feat: implement ExecuteStepWorker — step executor with idempotency"
```

## Task 6: ResumeWorker

**Files:**
- Create: `lib/hephaestus_oban/workers/resume_worker.ex`
- Create: `test/hephaestus_oban/workers/resume_worker_test.exs`

- [ ] **Step 1: Write failing tests**

Tests covering:
- Inserts step_result with event, enqueues AdvanceWorker
- Does NOT modify Instance directly
- Atomic: step_result insert + AdvanceWorker enqueue in transaction
- config_key in args is used to resolve config

- [ ] **Step 2: Implement ResumeWorker**

Per spec: only writes to step_results, never touches Instance.

- [ ] **Step 3: Run tests**

Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add lib/hephaestus_oban/workers/resume_worker.ex test/hephaestus_oban/workers/resume_worker_test.exs
git commit -m "feat: implement ResumeWorker — external events and durable timers"
```

## Task 7: FailureHandler (telemetry)

**Files:**
- Create: `lib/hephaestus_oban/failure_handler.ex`
- Create: `test/hephaestus_oban/failure_handler_test.exs`

- [ ] **Step 1: Write failing tests**

Tests covering:
- Attaches to telemetry
- Handles :discard state for ExecuteStepWorker -> enqueues AdvanceWorker with correct config
- Ignores non-ExecuteStepWorker discards
- Ignores non-discard states

- [ ] **Step 2: Implement FailureHandler**

Per spec: extracts config_key from job.args, resolves Oban name via persistent_term.

- [ ] **Step 3: Run tests**

Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add lib/hephaestus_oban/failure_handler.ex test/hephaestus_oban/failure_handler_test.exs
git commit -m "feat: implement FailureHandler — telemetry listener for discarded jobs"
```

## Task 8: Runner module (@behaviour implementation)

**Files:**
- Create: `lib/hephaestus_oban/runner.ex`
- Create: `test/hephaestus_oban/runner_test.exs`

- [ ] **Step 1: Write failing tests**

Tests covering:
- start_instance: persists Instance, enqueues AdvanceWorker, returns {:ok, id}
- resume: enqueues ResumeWorker with correct args including config_key
- schedule_resume: enqueues ResumeWorker with scheduled_at, returns {:ok, job_id}

- [ ] **Step 2: Implement Runner**

Per spec: stores config in persistent_term, delegates to workers. `start_link` populates persistent_term AND calls `HephaestusOban.FailureHandler.attach()` to register the telemetry handler. `child_spec` returns `:temporary` restart.

- [ ] **Step 3: Run tests**

Expected: all pass

- [ ] **Step 4: Commit**

```bash
git add lib/hephaestus_oban/runner.ex test/hephaestus_oban/runner_test.exs
git commit -m "feat: implement Runner behaviour with Oban jobs"
```

## Task 9: Integration tests — full workflow execution

**Files:**
- Create: `test/hephaestus_oban/integration_test.exs`

- [ ] **Step 1: Write integration tests**

Tests covering:
- Linear workflow: start -> advance -> execute step -> advance -> completed
- Async workflow: start -> execute -> {:async} -> waiting -> resume -> completed
- Fan-out/fan-in: 3 parallel steps -> all complete -> join step activated
- Failure: step fails after max_attempts -> workflow :failed
- Timer: schedule_resume creates job with correct scheduled_at

These tests use `Oban.Testing` to drain queues and verify job insertion.

- [ ] **Step 2: Run all tests**

Run: `mix test`
Expected: all pass

- [ ] **Step 3: Commit**

```bash
git add test/hephaestus_oban/integration_test.exs
git commit -m "test: add integration tests for full workflow execution"
```

## Task 10: Clean scaffold, update top-level module

**Files:**
- Modify: `lib/hephaestus_oban.ex`
- Delete: `test/hephaestus_oban_test.exs`

- [ ] **Step 1: Replace scaffold module**

```elixir
defmodule HephaestusOban do
  @moduledoc """
  Oban-based runner adapter for Hephaestus workflow instances.

  ## Usage

      defmodule MyApp.Hephaestus do
        use Hephaestus,
          storage: {HephaestusEcto.Storage, repo: MyApp.Repo},
          runner: {HephaestusOban.Runner, oban: MyApp.Oban}
      end

  ## Setup

      $ mix hephaestus_oban.gen.migration
      $ mix ecto.migrate
  """
end
```

- [ ] **Step 2: Delete scaffold test**

Remove `test/hephaestus_oban_test.exs`.

- [ ] **Step 3: Run all tests**

Run: `mix test`
Expected: all pass, zero warnings

- [ ] **Step 4: Commit**

```bash
git rm test/hephaestus_oban_test.exs
git add lib/hephaestus_oban.ex
git commit -m "docs: update top-level module, remove scaffold test"
```
