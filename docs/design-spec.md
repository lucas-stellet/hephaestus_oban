# Design Spec: hephaestus_oban

> Date: 2026-04-06
> Status: Approved
> Full spec: hephaestus_core/docs/superpowers/specs/2026-04-06-hephaestus-ecto-oban-design.md

## Overview

Oban-backed runner implementing `Hephaestus.Runtime.Runner`. Each workflow step becomes an Oban job with retry/backoff. Uses the consumer app's Oban instance — no internal Oban. Depends on `hephaestus_ecto` for persistent storage.

```
┌──────────────────────────────────────────────────────────┐
│  Consumer App                                            │
│                                                          │
│  defmodule MyApp.Hephaestus do                           │
│    use Hephaestus,                                       │
│      storage: {HephaestusEcto.Storage, repo: MyApp.Repo},│
│      runner: {HephaestusOban.Runner, oban: MyApp.Oban}   │
│  end                                                     │
└────────────┬─────────────────────────┬───────────────────┘
             │                         │
     ┌───────▼───────┐       ┌────────▼────────┐
     │hephaestus_ecto│       │ hephaestus_oban  │  ← this package
     │               │       │                  │
     │ Storage impl  │◄──────│ Runner impl      │
     │ Ecto + PG     │       │ 3 Oban workers   │
     └───────┬───────┘       │ step_results tbl │
             │               │ Telemetry handler│
     ┌───────▼───────┐       │ Migration gen    │
     │hephaestus_core│       └────────┬─────────┘
     │               │◄──────────────┘
     │ Runner behav. │
     │ Engine (pure) │
     └───────────────┘
```

## Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:hephaestus, "~> 0.2.0"},
    {:hephaestus_ecto, "~> 0.1"},
    {:oban, "~> 2.14"}
  ]
end
```

**Minimum Oban version:** 2.14+ required for `unique: [period: :infinity, states: [...]]` and stable `[:oban, :job, :stop]` telemetry with `:discard` state in metadata.

## Worker Configuration Access

Oban workers are stateless — they only receive `%Oban.Job{args: ...}`. They need access to the Repo, the Oban instance name, and the Storage name.

**Solution:** `HephaestusOban.Runner` stores config in `:persistent_term` during `start_link`, keyed by a config name derived from the entry module. Workers receive the config key in their job args and resolve everything from it.

```elixir
# At startup (called from supervision tree via use Hephaestus)
:persistent_term.put({HephaestusOban, :config, "my_app_hephaestus"}, %{
  repo: MyApp.Repo,
  oban: MyApp.Oban,
  storage: {HephaestusEcto.Storage, MyApp.Hephaestus.Storage}
})

# Every job args includes: %{"instance_id" => id, "config_key" => "my_app_hephaestus"}
# Workers resolve config via:
defp config(job), do: :persistent_term.get({HephaestusOban, :config, job.args["config_key"]})
```

Same pattern `Runner.Local` uses with `remember_registry/1`. After VM restart, the supervision tree repopulates the persistent_term before any Oban job runs.

## Database Schema — step_results

Auxiliary table for zero-contention parallel step execution.

```sql
CREATE TABLE hephaestus_step_results (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  instance_id     UUID         NOT NULL REFERENCES workflow_instances(id) ON DELETE CASCADE,
  step_ref        VARCHAR(255) NOT NULL,
  event           VARCHAR(255) NOT NULL,
  workflow_version INTEGER     NOT NULL DEFAULT 1,
  context_updates JSONB        NOT NULL DEFAULT '{}',
  metadata_updates JSONB       NOT NULL DEFAULT '{}',
  processed       BOOLEAN      NOT NULL DEFAULT false,
  inserted_at     TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE INDEX idx_step_results_pending ON hephaestus_step_results (instance_id) WHERE NOT processed;

-- Prevents duplicate step_results for the same step while unprocessed.
-- INSERT uses ON CONFLICT DO NOTHING so concurrent/retry inserts are idempotent.
CREATE UNIQUE INDEX idx_step_results_unique
  ON hephaestus_step_results (instance_id, step_ref) WHERE NOT processed;
```

**Why a separate table instead of optimistic locking on Instance:**
- Fan-out: N ExecuteStepWorkers write in parallel — each inserts its own row, zero contention
- No lost updates — AdvanceWorker is the single writer for the Instance
- No false retries polluting Oban dashboard
- No re-execution of side-effects (email sent twice, payment charged twice)

## Workers

### AdvanceWorker

Orchestrator. **Single writer for Instance.** Serialized per instance via Oban unique + PostgreSQL advisory lock.

**Unique constraint:** `period: :infinity` covering all non-terminal states prevents duplicate AdvanceWorkers.

**Advisory lock:** `pg_advisory_xact_lock` inside `Repo.transaction` as second layer of defense — truly serializes execution even if two AdvanceWorkers slip past the unique check on different nodes.

```elixir
defmodule HephaestusOban.AdvanceWorker do
  use Oban.Worker,
    queue: :hephaestus,
    unique: [keys: [:instance_id], period: :infinity,
             states: [:available, :scheduled, :executing, :retryable]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"instance_id" => instance_id}} = job) do
    config = resolve_config(job)

    # Uses first 8 bytes of UUID binary as 64-bit advisory lock key —
    # virtually eliminates collisions vs phash2 (27-bit).
    <<lock_key::signed-integer-64, _rest::binary>> = Ecto.UUID.dump!(instance_id)

    # Detect discarded steps BEFORE entering the transaction/advisory lock.
    # This avoids holding the lock while querying the Oban jobs table.
    discarded = detect_discarded_steps(config, instance_id)

    result =
      config.repo.transaction(fn ->
        # Serializes execution per instance — releases when transaction ends
        config.repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])

        instance = load_instance(config, instance_id)

        # 1. Apply pending step_results
        pending = StepResults.pending_for(config.repo, instance_id)
        instance = apply_step_results(instance, pending)

        # 2. Check for discarded step jobs -> workflow failure
        if discarded != [] do
          instance = fail_workflow(config, instance)
          persist(config, instance)
          StepResults.mark_processed(config.repo, pending)
          {:failed, instance}
        else
          # 3. Engine.advance (handles pending -> running, empty active -> completed)
          {:ok, instance} = Engine.advance(instance)

          # 4. Persist instance + mark results processed (atomic)
          persist(config, instance)
          StepResults.mark_processed(config.repo, pending)

          {:continue, instance}
        end
      end)

    # Failure handling happens OUTSIDE the transaction — no need to hold
    # the advisory lock while cancelling jobs or emitting telemetry.
    case result do
      {:ok, {:failed, instance}} ->
        cancel_pending_jobs(config, instance)
        :ok

      {:ok, {:continue, instance}} ->
        case instance do
          %{status: s} when s in [:completed, :failed, :waiting] -> :ok
          %{active_steps: active} ->
            active
            |> MapSet.to_list()
            |> Enum.each(&enqueue_execute_step(config, instance_id, &1))
        end
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

**Key guarantees:**
- `pg_advisory_xact_lock` + `Repo.transaction` ensures step_results processing and Instance persist are atomic — no partial state on crash
- Advisory lock auto-releases when transaction ends (commit or crash)
- Unique constraint prevents queue buildup of duplicate AdvanceWorkers

**apply_step_results/2 iterates each pending result (applied in inserted_at order — FIFO):**
```
pending_for query includes ORDER BY inserted_at ASC.

for each step_result:
  step_module = String.to_existing_atom(step_result.step_ref)

  if step_result.event == "__async__":
    # Sentinel: sets instance.status = :waiting and instance.current_step = step_module.
    # Does NOT call complete_step or activate_transitions — the step hasn't completed,
    # it's signaling that it needs an external event to continue.
    instance = %{instance | status: :waiting, current_step: step_module}
  else:
    event = String.to_existing_atom(step_result.event)
    instance = Engine.complete_step(instance, step_module, event, step_result.context_updates)
    instance = Engine.activate_transitions(instance, step_module, event)

instance = Engine.check_completion(instance)
```

Events and step_refs are stored as strings in the DB and converted back to atoms via `String.to_existing_atom/1` before passing to Engine functions (which expect atoms).

**context_updates JSON normalization:** `context_updates` is stored as JSONB, which means atom keys are lost on round-trip (they become string keys). Workers and `apply_step_results` must treat `context_updates` as string-keyed maps. The Engine's `Context.put_step_result/3` already accepts string keys — no conversion needed.

When processing a resume step_result (instance is `:waiting`), AdvanceWorker transitions status to `:running` before applying `complete_step`, since the Engine expects a non-waiting instance for completion.

### ExecuteStepWorker

Executes a single step. Writes result to step_results table. **Never touches Instance directly.**

```elixir
defmodule HephaestusOban.ExecuteStepWorker do
  use Oban.Worker,
    queue: :hephaestus,
    unique: [keys: [:instance_id, :step_ref], period: :infinity,
             states: [:available, :scheduled, :executing, :retryable]]

  # max_attempts set dynamically from retry_config

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"instance_id" => id, "step_ref" => step_ref}} = job) do
    config = resolve_config(job)

    # Idempotency: if a step_result already exists (unprocessed), skip execution.
    # Prevents re-running side-effects on Oban retry after insert succeeded but job ack failed.
    if StepResults.exists?(config.repo, id, step_ref), do: {:ok, :already_recorded}

    instance = load_instance(config, id)  # read-only, for context
    step_module = String.to_existing_atom(step_ref)

    case Engine.execute_step(instance, step_module) do
      {:ok, event} ->
        # StepResults.insert and Oban.insert(AdvanceWorker) are wrapped in
        # Repo.transaction using Oban.insert/3 (Oban 2.12+) for atomicity.
        insert_result_and_advance(config, id, step_ref, to_string(event), %{})
        :ok

      {:ok, event, context_updates} ->
        insert_result_and_advance(config, id, step_ref, to_string(event), context_updates)
        :ok

      {:async} ->
        # Insert sentinel step_result instead of mutating Instance directly.
        # AdvanceWorker is the single writer — it will set status = :waiting.
        insert_result_and_advance(config, id, step_ref, "__async__", %{})
        :ok

      {:error, reason} ->
        {:error, reason}  # Oban handles retry
    end
  end
end
```

**Retry config resolution (most specific wins):**

```
1. Step.retry_config/0              <- per step (optional callback)
2. Workflow.default_retry_config/0  <- per workflow (optional callback)
3. HephaestusOban default           <- %{max_attempts: 5, backoff: :exponential}
4. Oban queue config                <- most generic
```

The AdvanceWorker resolves retry config when creating ExecuteStepWorker jobs:

```elixir
defp enqueue_execute_step(config, instance_id, step_module) do
  retry = resolve_retry_config(instance_id, step_module)

  HephaestusOban.ExecuteStepWorker.new(
    %{instance_id: instance_id, step_ref: to_string(step_module),
      config_key: config.key},
    max_attempts: retry.max_attempts
  )
  |> Oban.insert(config.oban)
end
```

### ResumeWorker

Handles external events and durable timers. Follows the same pattern as ExecuteStepWorker: **writes only to step_results, never to the Instance directly.** AdvanceWorker remains the single Instance writer.

`Engine.resume_step/3` internally calls `complete_step` + `activate_transitions`. To preserve the single-writer invariant, ResumeWorker does NOT call Engine.resume_step. Instead, it inserts a step_result with the resume event, and AdvanceWorker applies it — achieving the same result without direct Instance mutation.

```elixir
defmodule HephaestusOban.ResumeWorker do
  use Oban.Worker, queue: :hephaestus, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"instance_id" => id, "step_ref" => step_ref, "event" => event, "config_key" => config_key}} = job) do
    config = resolve_config(job)

    # Only write to step_results — AdvanceWorker will apply.
    # StepResults.insert and Oban.insert(AdvanceWorker) are wrapped in
    # Repo.transaction using Oban.insert/3 (Oban 2.12+) for atomicity.
    insert_result_and_advance(config, id, step_ref, event, %{})

    :ok
  end
end
```

## Failure Detection via Telemetry

```elixir
defmodule HephaestusOban.FailureHandler do
  @doc """
  Attaches to Oban telemetry to detect discarded ExecuteStepWorker jobs.
  When a step job exhausts all retries, enqueues an AdvanceWorker
  so it can detect the failure and mark the workflow as :failed.
  """
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
      Oban.insert(config.oban, HephaestusOban.AdvanceWorker.new(%{instance_id: instance_id, config_key: config_key}))
    end
  end

  def handle_event(_event, _measure, _meta, _config), do: :ok
end
```

AdvanceWorker detects discarded steps by querying Oban jobs table for the instance, then marks the workflow as `:failed` and cancels remaining pending jobs.

## Runner Public API

```elixir
defmodule HephaestusOban.Runner do
  @behaviour Hephaestus.Runtime.Runner

  @impl Runner
  def start_instance(workflow, context, opts) do
    storage = Keyword.fetch!(opts, :storage)
    config_key = Keyword.fetch!(opts, :config_key)
    oban = Keyword.fetch!(opts, :oban)
    workflow_version = Keyword.get(opts, :workflow_version, 1)

    instance = Instance.new(workflow, workflow_version, context)
    :ok = storage_put(storage, instance)

    Oban.insert(oban, AdvanceWorker.new(%{
      "instance_id" => instance.id,
      "config_key" => config_key,
      "workflow" => to_string(workflow),
      "workflow_version" => workflow_version
    }))

    {:ok, instance.id}
  end

  @impl Runner
  def resume(instance_id, event) do
    config = resolve_config()
    Oban.insert(config.oban, ResumeWorker.new(%{
      instance_id: instance_id,
      step_ref: get_current_step(config, instance_id),
      event: to_string(event),
      config_key: config.key
    }))
    :ok
  end

  @impl Runner
  def schedule_resume(instance_id, step_ref, delay_ms) do
    config = resolve_config()
    {:ok, %Oban.Job{id: job_id}} = Oban.insert(config.oban, ResumeWorker.new(
      %{instance_id: instance_id, step_ref: to_string(step_ref),
        event: "timeout", config_key: config.key},
      scheduled_at: DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
    ))
    # Return job_id — can be used with Oban.cancel_job/1 to cancel the timer
    {:ok, job_id}
  end
end
```

## Complete Flow Diagram

```
start_instance(OrderWorkflow, %{order_id: 123})
  │
  ├─ Instance.new(workflow, workflow_version, context) -> persist via HephaestusEcto.Storage
  └─ Oban.insert(AdvanceWorker)
       │
       ▼
  AdvanceWorker
  │ Engine.advance() -> active_steps: {Validate, Charge, Notify}
  │ persist Instance
  └─ enqueue 3x ExecuteStepWorker
       │
       ├─ ExecuteStepWorker(Validate) ──┐
       ├─ ExecuteStepWorker(Charge)  ───┤  parallel, zero contention
       └─ ExecuteStepWorker(Notify)  ───┤
                                        │
       each: execute step               │
             INSERT step_results        │
             enqueue AdvanceWorker      │
                                        ▼
  AdvanceWorker (unique + advisory lock, serialized)
  │ SELECT step_results WHERE NOT processed
  │ apply each: Engine.complete_step + activate_transitions
  │ Engine.check_completion()
  │ persist Instance
  │
  ├─ :completed -> done
  ├─ :waiting   -> done (awaits ResumeWorker)
  └─ active_steps not empty -> enqueue ExecuteStepWorkers (next wave)

  --- async step flow ---

  ExecuteStepWorker(WaitForEvent)
  │ Engine.execute_step -> {:async}
  │ INSERT step_results(step, "__async__")  <- sentinel, not a real event
  └─ enqueue AdvanceWorker
       │
       ▼
  AdvanceWorker
  │ detects __async__ step_result
  │ sets instance.status = :waiting, current_step = step
  └─ done (awaits ResumeWorker)

       ... external event ...

  Runner.resume(id, :payment_confirmed)
  └─ Oban.insert(ResumeWorker)
       │
       ▼
  ResumeWorker
  │ INSERT step_results(step, event)  <- only writes to step_results
  └─ enqueue AdvanceWorker
       │
       ▼
  AdvanceWorker
  │ detects instance is :waiting + resume step_result pending
  │ sets status :running, applies complete_step + activate_transitions
  │ persist
  └─ enqueue ExecuteStepWorkers -> cycle continues

  --- failure flow ---

  ExecuteStepWorker(Charge)
  │ attempt 1 -> {:error, :timeout}     (Oban retries)
  │ attempt 2 -> {:error, :timeout}
  │ attempt N -> {:error, :timeout}     -> DISCARDED
  │
  ▼
  FailureHandler (telemetry)
  │ detects discard
  └─ enqueue AdvanceWorker
       │
       ▼
  AdvanceWorker
  │ detect_discarded_steps -> [:Charge]
  │ instance.status = :failed
  │ cancel pending jobs
  └─ done

  --- durable timer flow ---

  ExecuteStepWorker(Wait)
  │ {:async} -> INSERT step_results(__async__) + enqueue AdvanceWorker
  │ Runner.schedule_resume(id, :wait, 30_000)
  └─ Oban.insert(ResumeWorker, scheduled_at: now + 30s)

       ... 30 seconds later (survives crash, VM restart) ...

  ResumeWorker
  │ INSERT step_results(:wait, "timeout")
  └─ enqueue AdvanceWorker -> applies resume, cycle continues
```

## Concurrency Model

### Problem

In fan-out, N ExecuteStepWorkers run in parallel. If they all update the Instance directly:
- Lost updates (last writer wins, earlier changes lost)
- Re-execution of side-effects on retry (email sent twice)
- False errors in Oban dashboard from optimistic lock retries

### Solution

ExecuteStepWorkers and ResumeWorkers never write to the Instance. They INSERT into `step_results` (zero contention — each writes its own row). AdvanceWorker is the **single writer** for the Instance, serialized via Oban unique constraint + PostgreSQL advisory lock. All Instance mutations happen inside a `Repo.transaction` with `pg_advisory_xact_lock` — ensuring atomicity between step_results processing and Instance persistence.

### Fan-in Behavior

Fan-in is handled by the Engine's existing `__predecessors__` check:

```
AdvanceWorker applies step_result(C):
  Engine.activate_transitions(C) -> target is JoinStep
  Engine.maybe_activate_step(JoinStep):
    predecessors = workflow.__predecessors__(JoinStep)  # {A, B, C}
    MapSet.subset?({A, B, C}, completed_steps)
    -> if {A, B, C} ⊆ {B, C} -> false, don't activate
    -> if {A, B, C} ⊆ {A, B, C} -> true, activate JoinStep
```

No special handling needed — the Engine's pure functional logic handles fan-in correctly.

## Error Handling

| Scenario | Handler | Outcome |
|----------|---------|---------|
| Step returns `{:error, reason}` | Oban retry with backoff | Retried up to max_attempts |
| Step exhausts all retries | FailureHandler (telemetry) | Workflow marked `:failed` |
| Step crashes/raises | Oban catches, treats as error | Same retry flow |
| AdvanceWorker fails | Oban retry | Idempotent — re-applies unprocessed step_results |
| ResumeWorker fails | Oban retry | Idempotent — INSERT step_result deduplicated or no-op if already processed |
| DB connection lost | Oban retry | All workers are idempotent |
| Instance stuck (no jobs) | ReconcileWorker (cron, future) | Safety net, not in MVP |

## Migration Generator

```bash
mix hephaestus_oban.gen.migration
```

Generates migration for `hephaestus_step_results` table. Requires `hephaestus_ecto` migration to be run first (FK reference).

## Consumer Usage

```elixir
# mix.exs
{:hephaestus_ecto, "~> 0.1"},
{:hephaestus_oban, "~> 0.4.0"}

# Generate and run migrations
$ mix hephaestus_ecto.gen.migration
$ mix hephaestus_oban.gen.migration
$ mix ecto.migrate

# lib/my_app/hephaestus.ex — all config here
defmodule MyApp.Hephaestus do
  use Hephaestus,
    storage: {HephaestusEcto.Storage, repo: MyApp.Repo},
    runner: {HephaestusOban.Runner, oban: MyApp.Oban}
end

# application.ex
children = [
  MyApp.Repo,
  {Oban, name: MyApp.Oban, repo: MyApp.Repo, queues: [hephaestus: 10]},
  MyApp.Hephaestus
]
```

**Queue concurrency note:** The `hephaestus: 10` means up to 10 Oban jobs run concurrently in the hephaestus queue. In a fan-out of 20 steps, only 10 execute at once — the rest wait. This is expected behavior, not a bug. Adjust the queue limit based on workload.

**Queue separation:** Consumers may use separate queues for AdvanceWorker (low-concurrency, serialized) vs ExecuteStepWorker (higher concurrency for fan-out). Example: `queues: [hephaestus_advance: 5, hephaestus_execute: 20]`. The queue name is configurable via the Runner opts and defaults to `:hephaestus` for all workers.

## Module Structure

```
lib/
  hephaestus_oban.ex         # Top-level module
  hephaestus_oban/
    runner.ex                # @behaviour Runner implementation
    workers/
      advance_worker.ex      # Orchestrator, single Instance writer
      execute_step_worker.ex # Step executor, writes to step_results
      resume_worker.ex       # External events and durable timers
    step_results.ex          # CRUD for step_results table
    failure_handler.ex       # Telemetry listener for discarded jobs
    retry_config.ex          # Retry config resolution logic
    schema/
      step_result.ex         # Ecto schema for step_results
    migration.ex             # Migration module used by generator
mix/
  tasks/
    hephaestus_oban.gen.migration.ex  # Mix task
```

## Required Changes in hephaestus_core

1. **Macro `use Hephaestus`** — accept tuple `{module, opts}` in `storage:` and `runner:`
2. **Step behaviour** — add optional `retry_config/0` callback
3. **Runner behaviour** — change `schedule_resume` return from `{:ok, reference()}` to `{:ok, term()}`
4. **runner_opts propagation** — merge runner-specific opts into runner_opts

All backward compatible — Runner.Local + Storage.ETS continue working unchanged.

## Testing Strategy

- Unit tests: each worker in isolation with mocked storage
- Integration tests: full workflow execution (linear, fan-out/fan-in, async/resume) against real Postgres + Oban
- Failure tests: step failure -> retry -> discard -> workflow :failed
- Timer tests: schedule_resume creates Oban job with correct scheduled_at
- Concurrency tests: fan-out with 3+ parallel steps, verify no lost updates via step_results
- Advisory lock tests: verify serialization under concurrent AdvanceWorker attempts
- Retry config tests: per-step override, workflow default, global fallback
