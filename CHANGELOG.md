# Changelog

All notable changes to this project will be documented in this file.

## v0.2.0 (2026-04-07)

### Enhancements

- Add workflow metadata and tags to Oban jobs via `HephaestusOban.JobMetadata`
- Require `hephaestus ~> 0.1.3` for metadata support

### Docs

- Add observability section to README
- Add moduledoc to `HephaestusOban` and `HephaestusOban.JobMetadata` for hexdocs

## v0.1.0 (2026-04-07)

### Initial release

- Oban-based runner adapter for the Hephaestus workflow engine
- Durable jobs with retry/backoff via Oban
- Advisory lock serialization for step execution
- Zero-contention parallel step execution via auxiliary `step_results` table
- Package metadata and LICENSE for hex.pm publishing
