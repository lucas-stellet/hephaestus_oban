# CLAUDE.md

## Project

`hephaestus_oban` — Oban-based runner adapter for the Hephaestus workflow engine.

## Changelog

This project maintains a `CHANGELOG.md` following the [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.
When releasing a new version:

1. Add a new section to `CHANGELOG.md` using the standard categories (`Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`)
2. The changelog is registered in `mix.exs` under `docs/extras` (hexdocs sidebar) and `package/files` (hex.pm package)

## Commands

- `mix test` — runs tests (auto-creates and migrates the test DB)
- `mix docs` — generates hexdocs locally

## Conventions

- Commit messages follow conventional commits: `feat:`, `fix:`, `chore:`, `docs:`
- Elixir ~> 1.19

## Versioned Migrations

This library ships versioned database migrations for the `hephaestus_step_results` table. The migration system follows the [Oban migration pattern](https://hexdocs.pm/oban/Oban.Migration.html).

### Architecture

```
lib/hephaestus_oban/migration.ex           — Public API (up/1, down/1, migrated_version/1)
lib/hephaestus_oban/migrations/postgres.ex  — Orchestrator (version tracking, routing)
lib/hephaestus_oban/migrations/postgres/
  v01.ex — Creates hephaestus_step_results table with FK to workflow_instances
  v02.ex — Adds metadata_updates column
  v03.ex — Adds workflow_version column
```

### How version tracking works

- The applied schema version is stored as a **PostgreSQL table comment** on the `hephaestus_step_results` table.
- `migrated_version/1` reads this comment via a `pg_class` + `pg_namespace` JOIN query.
- `up/1` compares the current version to the target and runs only missing versions.
- `record_version/2` writes the new version as a comment after applying migrations.

### Key design decisions

1. **Query uses separate `relname` / `nspname` comparisons** (not concatenation or `::regclass` casts). This correctly handles both `public` and custom schema prefixes, and is safe when the table doesn't exist yet (no `::regclass` crash). Follows the exact pattern from Oban's `Oban.Migrations.Postgres.migrated_version/1`.

2. **All DDL operations are idempotent.** V01 uses `create_if_not_exists` for table and indexes. V02/V03 use `add_if_not_exists`. Re-running all migrations is safe even if the table comment is lost.

3. **`@disable_ddl_transaction` is NOT needed.** The `migrated_version` query is safe inside DDL transactions.

4. **`quoted_prefix`** is `inspect(prefix)` (e.g., `"public"`). Used in `COMMENT ON TABLE` DDL. **`escaped_prefix`** has single quotes escaped for SQL string literals.

### Adding a new migration version

1. Create `lib/hephaestus_oban/migrations/postgres/v04.ex` accepting `%{prefix: prefix}` in `up/1` and `down/1`.
2. Use idempotent operations: `add_if_not_exists`, `create_if_not_exists`, `drop_if_exists`, `remove_if_exists`.
3. Bump `@current_version` from `3` to `4` in `lib/hephaestus_oban/migrations/postgres.ex`.
4. Add tests in `test/hephaestus_oban/migrations/postgres_test.exs`.
5. Update `CHANGELOG.md`.

### Caveats for host applications

- **FK dependency**: `hephaestus_step_results` has a foreign key to `workflow_instances`. The `hephaestus_ecto` migration must run first.
- **Do not manually alter the `hephaestus_step_results` table.** Schema changes should come from the library's versioned migrations.
- **Lost comments**: if a backup strips table comments, `up()` re-runs all versions safely (idempotent DDL). Fix manually: `COMMENT ON TABLE "public".hephaestus_step_results IS '3'`.
