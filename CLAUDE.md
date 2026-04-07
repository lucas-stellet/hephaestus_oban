# CLAUDE.md

## Project

`hephaestus_oban` — Oban-based runner adapter for the Hephaestus workflow engine.

## Changelog

This project maintains a `CHANGELOG.md` at the root. When releasing a new version:

1. Add a new section to `CHANGELOG.md` following the existing format (`## vX.Y.Z (YYYY-MM-DD)`)
2. The changelog is registered in `mix.exs` under `docs/extras` (hexdocs sidebar) and `package/files` (hex.pm package)

## Commands

- `mix test` — runs tests (auto-creates and migrates the test DB)
- `mix docs` — generates hexdocs locally

## Conventions

- Commit messages follow conventional commits: `feat:`, `fix:`, `chore:`, `docs:`
- Elixir ~> 1.19
