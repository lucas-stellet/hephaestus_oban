# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.5.0] - 2026-04-13

### Added

- Migration V04: changes `hephaestus_step_results.instance_id` from `uuid` to `varchar(255)` to support business key IDs (`"key::value"` format).
- Storage filter verification tests for `:id`, `:status_in`, `:workflow_version`, and combined filters.

### Changed

- **Breaking:** `start_instance/3` now requires `:id` in opts — the runner passes it to `Instance.new/4` (explicit business key ID).
- V01 migration updated to create FK with `type: :string` (compatible with fresh installs on hephaestus_ecto 0.3.0+).
- `StepResult` schema: `instance_id` field changed from `:binary_id` to `:string`.
- Advisory lock key generation uses `:erlang.phash2/1` instead of `Ecto.UUID.dump!/1` (supports non-UUID instance IDs).
- All test workflows declare `unique: [key: "testoban"]` (required by hephaestus 0.3.0).
- Requires `hephaestus ~> 0.3.0` and `hephaestus_ecto ~> 0.3.0`.

## [0.4.1] - 2026-04-09

### Fixed

- Fixed `migrated_version/1` query — replaced `::regclass` cast (which crashes when the table doesn't exist on fresh install, aborting the DDL transaction) with a safe `pg_class` + `pg_namespace` JOIN query. Host applications no longer need `@disable_ddl_transaction` in their migration files.
- Fixed `record_version/2` to always include the schema prefix using `quoted_prefix`.
- Made V01 migration fully idempotent: `create` → `create_if_not_exists` for table and indexes.
- Added `:prefix` support to all migration versions (V01, V02, V03) for multi-tenant use.
- Removed unused `qualified_table/2` private function from the orchestrator.
- Added `quoted_prefix` to opts (via `with_defaults/2`) following Oban's pattern.
- Added migration tests for `migrated_version` when table doesn't exist.

## [0.4.0] - 2026-04-08

### Added

- Versioned migration system following the Oban pattern (V01, V02, V03).
- `HephaestusOban.Migration.up/1` and `down/1` with version tracking via table comments.
- Migration V03: `workflow_version` integer column on `hephaestus_step_results` (NOT NULL, default 1).
- `workflow_version` in Oban job args for all workers (AdvanceWorker, ExecuteStepWorker, ResumeWorker).
- `workflow_version` in JobMetadata for Oban Web observability.

### Changed

- Refactored `migration.ex` into versioned modules (V01: initial table, V02: metadata_updates, V03: workflow_version) with orchestrator pattern.
- `StepResults.insert/1` now persists `workflow_version`.
- Runner updated to use `Instance.new/3`.
- Requires `hephaestus ~> 0.2.0`.

## [0.3.0] - 2026-04-08

### Added

- Runtime metadata support: `ExecuteStepWorker` handles `{:ok, event, context_updates, metadata_updates}` from steps.
- `metadata_updates` column in `hephaestus_step_results` table.
- Temporary `add_metadata_updates/0` upgrade helper for existing tables.
- `runtime_metadata` option in `JobMetadata.build/3` — dynamic metadata from steps appears in Oban job meta.

### Changed

- `AdvanceWorker` passes `runtime_metadata` to `Engine.complete_step/5` and propagates it to subsequent job metadata.

## [0.2.0] - 2026-04-07

### Added

- Workflow metadata and tags to Oban jobs via `HephaestusOban.JobMetadata`
- Observability section to README
- Moduledoc to `HephaestusOban` and `HephaestusOban.JobMetadata` for hexdocs

### Changed

- Require `hephaestus ~> 0.1.3` for metadata support

## [0.1.0] - 2026-04-07

### Added

- Oban-based runner adapter for the Hephaestus workflow engine
- Durable jobs with retry/backoff via Oban
- Advisory lock serialization for step execution
- Zero-contention parallel step execution via auxiliary `step_results` table
- Package metadata and LICENSE for hex.pm publishing
