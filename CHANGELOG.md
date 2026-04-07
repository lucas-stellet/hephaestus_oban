# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
