# Task 002: Migration, step_results schema + CRUD, mix task

**Wave**: 1 | **Effort**: M
**Depends on**: task-001
**Blocks**: task-004, task-005

## Objective

Create the `hephaestus_step_results` database table via a migration module, its Ecto schema, a CRUD module for querying/inserting/updating step results, and a mix task for consumers to generate the migration.

## Files

**Create:** `lib/hephaestus_oban/migration.ex` — Ecto migration for step_results table
**Create:** `lib/hephaestus_oban/schema/step_result.ex` — Ecto schema
**Create:** `lib/hephaestus_oban/step_results.ex` — CRUD operations module
**Create:** `lib/mix/tasks/hephaestus_oban.gen.migration.ex` — mix task for migration generation

## Requirements

### Migration module (`lib/hephaestus_oban/migration.ex`)

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

### Schema (`lib/hephaestus_oban/schema/step_result.ex`)

- Primary key: `{:id, :binary_id, autogenerate: true}`
- Table: `"hephaestus_step_results"`
- Fields: `instance_id` (binary_id), `step_ref` (string), `event` (string), `context_updates` (map, default `%{}`), `processed` (boolean, default false), `inserted_at` (utc_datetime_usec)
- Changeset: cast `[:instance_id, :step_ref, :event, :context_updates]`, validate_required `[:instance_id, :step_ref, :event]`

### StepResults CRUD (`lib/hephaestus_oban/step_results.ex`)

Functions (all take `repo` as first arg):

- `insert(repo, instance_id, step_ref, event, context_updates)` — Inserts a step result. Uses `on_conflict: :nothing` with `conflict_target: {:unsafe_fragment, ~s|(instance_id, step_ref) WHERE NOT processed|}` for idempotency. Returns `:ok`.
- `exists?(repo, instance_id, step_ref)` — Returns boolean, checks for unprocessed result matching instance_id + step_ref.
- `pending_for(repo, instance_id)` — Returns all unprocessed results for instance, ordered by `inserted_at ASC`.
- `mark_processed(repo, results)` — Takes list of StepResult structs, updates `processed = true` for all matching IDs. Returns `:ok`.

### Mix task (`lib/mix/tasks/hephaestus_oban.gen.migration.ex`)

Same pattern as hephaestus_ecto's mix task. Generates a migration file in the consumer app's `priv/repo/migrations/` that calls `HephaestusOban.Migration.up/0` and `down/0`.

### Verification

Run `mix ecto.create && mix ecto.migrate` — tables must be created successfully.

## Done when

- [ ] Migration module compiles and creates correct table with indexes
- [ ] Schema module compiles with correct fields and changeset
- [ ] StepResults CRUD module compiles with all 4 functions
- [ ] Mix task generates migration file correctly
- [ ] `mix ecto.migrate` succeeds (step_results table created)
