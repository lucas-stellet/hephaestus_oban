# HephaestusOban

Oban-based runner adapter for [Hephaestus](https://github.com/lucas-stellet/hephaestus) workflow engine.

Turns each workflow step into a durable Oban job with retry/backoff, advisory lock serialization, and zero-contention parallel execution via an auxiliary `step_results` table.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:hephaestus_oban, "~> 0.1.0"}
  ]
end
```

## Setup

### 1. Generate and run migrations

Requires [HephaestusEcto](https://github.com/lucas-stellet/hephaestus_ecto) migration to be run first (FK reference).

```bash
mix hephaestus_ecto.gen.migration
mix hephaestus_oban.gen.migration
mix ecto.migrate
```

### 2. Configure your workflow engine

```elixir
defmodule MyApp.Hephaestus do
  use Hephaestus,
    storage: {HephaestusEcto.Storage, repo: MyApp.Repo},
    runner: {HephaestusOban.Runner, oban: MyApp.Oban}
end
```

### 3. Add to your supervision tree

```elixir
children = [
  MyApp.Repo,
  {Oban, name: MyApp.Oban, repo: MyApp.Repo, queues: [hephaestus: 10]},
  MyApp.Hephaestus
]
```

## How it works

### Architecture

```
start_instance(Workflow, context)
  |
  +-- Instance.new() --> persist via HephaestusEcto.Storage
  +-- Oban.insert(AdvanceWorker)
       |
       v
  AdvanceWorker (single Instance writer, advisory lock)
  | Engine.advance() --> active_steps: {StepA, StepB, StepC}
  +-- enqueue 3x ExecuteStepWorker
       |
       +-- ExecuteStepWorker(StepA) --+
       +-- ExecuteStepWorker(StepB) --+  parallel, zero contention
       +-- ExecuteStepWorker(StepC) --+
                                      |
       each: execute step             |
             INSERT step_results      |
             enqueue AdvanceWorker    |
                                      v
  AdvanceWorker (serialized via unique + advisory lock)
  | apply step_results --> Engine.complete_step + activate_transitions
  | persist Instance
  |
  +-- :completed --> done
  +-- :waiting   --> awaits ResumeWorker
  +-- active     --> enqueue ExecuteStepWorkers (next wave)
```

### Three workers

| Worker | Role | Writes to Instance? |
|--------|------|---------------------|
| **AdvanceWorker** | Orchestrator. Reads step_results, applies Engine transitions, persists Instance. Serialized per instance via Oban unique + `pg_advisory_xact_lock`. | Yes (single writer) |
| **ExecuteStepWorker** | Executes a single step. Writes result to `step_results` table, enqueues AdvanceWorker. Idempotent via existence check. | No |
| **ResumeWorker** | Handles external events and durable timers. Writes to `step_results`, enqueues AdvanceWorker. | No |

### Concurrency model

ExecuteStepWorkers run in parallel during fan-out. They never write to the Instance directly — each inserts its own row into `hephaestus_step_results` (zero contention). The AdvanceWorker is the **single writer** for the Instance, serialized via Oban unique constraint + PostgreSQL advisory lock. All Instance mutations happen atomically inside a `Repo.transaction` with `pg_advisory_xact_lock`.

### Failure handling

When an ExecuteStepWorker exhausts all retries (discarded by Oban), the `FailureHandler` telemetry listener detects it and enqueues an AdvanceWorker, which marks the workflow as `:failed` and cancels remaining pending jobs.

### Retry configuration

Retry config resolves with most-specific-wins priority:

1. `Step.retry_config/0` — per-step override (optional callback)
2. `Workflow.default_retry_config/0` — per-workflow default (optional callback)
3. Library default — `%{max_attempts: 5, backoff: :exponential, max_backoff: 60_000}`

### Async steps and durable timers

```elixir
# Step returns {:async} --> instance moves to :waiting
# Resume with external event:
MyApp.Hephaestus.resume(instance_id, :payment_confirmed)

# Schedule a durable timer (survives VM restarts):
MyApp.Hephaestus.schedule_resume(instance_id, :wait_step, 30_000)
# Returns {:ok, job_id} — cancellable via Oban.cancel_job/1
```

## Database schema

### step_results table

Auxiliary table for zero-contention parallel step execution:

```
hephaestus_step_results
+-- id               UUID (primary key)
+-- instance_id      UUID (FK -> workflow_instances, ON DELETE CASCADE)
+-- step_ref         STRING (module name)
+-- event            STRING (step event or "__async__" sentinel)
+-- context_updates  JSONB (step output data)
+-- processed        BOOLEAN (consumed by AdvanceWorker)
+-- inserted_at      TIMESTAMP
```

Indexes:
- Partial index on `instance_id WHERE NOT processed` — fast pending lookups
- Partial unique index on `(instance_id, step_ref) WHERE NOT processed` — idempotent inserts via `ON CONFLICT DO NOTHING`

## Queue configuration

```elixir
# Default: single queue for all workers
{Oban, queues: [hephaestus: 10]}

# Advanced: separate queues for orchestration vs execution
{Oban, queues: [hephaestus_advance: 5, hephaestus_execute: 20]}
```

The `hephaestus: 10` means up to 10 Oban jobs run concurrently. In a fan-out of 20 steps, only 10 execute at once — the rest wait. Adjust based on your workload.

## Error handling

| Scenario | Handler | Outcome |
|----------|---------|---------|
| Step returns `{:error, reason}` | Oban retry with backoff | Retried up to max_attempts |
| Step exhausts all retries | FailureHandler (telemetry) | Workflow marked `:failed` |
| Step crashes/raises | Oban catches, treats as error | Same retry flow |
| AdvanceWorker fails | Oban retry | Idempotent — re-applies unprocessed step_results |
| ResumeWorker fails | Oban retry | Idempotent — INSERT deduplicated via unique index |
| DB connection lost | Oban retry | All workers are idempotent |

## Requirements

- Elixir ~> 1.19
- Oban >= 2.14
- PostgreSQL (for advisory locks and JSONB)
- [Hephaestus](https://github.com/lucas-stellet/hephaestus) ~> 0.1
- [HephaestusEcto](https://github.com/lucas-stellet/hephaestus_ecto) ~> 0.1

## License

MIT
