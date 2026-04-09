# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Refactored `HephaestusOban.Migration` into a versioned migration system with orchestrator pattern (V01 for initial `hephaestus_step_results` table, V02 for `metadata_updates` column).

## [0.3.0] - 2026-04-08

### Added

- Runtime metadata support: `ExecuteStepWorker` handles `{:ok, event, context_updates, metadata_updates}` from steps.
- `metadata_updates` column in `hephaestus_step_results` table.
- `HephaestusOban.Migration.add_metadata_updates/0` for upgrading existing tables.
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
