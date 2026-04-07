# Task 001: Project setup — dependencies, config, test support

**Wave**: 0 | **Effort**: M
**Depends on**: none
**Blocks**: task-002, task-003

## Objective

Set up the project foundation: add all dependencies to `mix.exs`, create config files, create test support modules (TestRepo, test steps, test workflows), create test migrations, and configure `test_helper.exs`. Everything needed for subsequent tasks to compile and test against.

## Files

**Modify:** `mix.exs` — add deps, elixirc_paths, aliases
**Modify:** `lib/hephaestus_oban/application.ex` — empty supervision tree (library package)
**Create:** `config/config.exs` — import env-specific config
**Create:** `config/test.exs` — TestRepo + Oban test config
**Create:** `test/support/test_repo.ex` — Ecto Repo for tests
**Create:** `test/support/test_steps.ex` — PassStep, AsyncStep, FailStep, PassWithContextStep
**Create:** `test/support/test_workflows.ex` — LinearWorkflow, AsyncWorkflow
**Create:** `priv/repo/migrations/20260407000000_create_workflow_instances.exs` — calls HephaestusEcto.Migration
**Create:** `priv/repo/migrations/20260407000001_create_oban_jobs.exs` — calls Oban.Migration
**Create:** `priv/repo/migrations/20260407000002_create_step_results.exs` — calls HephaestusOban.Migration (placeholder, will be filled once task-002 creates the module)
**Modify:** `test/test_helper.exs` — start TestRepo, Oban, configure sandbox

## Requirements

### mix.exs

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

### application.ex — empty supervisor (library package, no Mix.env() at runtime)

```elixir
defmodule HephaestusOban.Application do
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([], strategy: :one_for_one, name: HephaestusOban.Supervisor)
  end
end
```

### config/config.exs

```elixir
import Config
import_config "#{config_env()}.exs"
```

### config/test.exs

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

### Test support modules

`test/support/test_repo.ex` — `HephaestusOban.TestRepo` using `Ecto.Repo` with `otp_app: :hephaestus_oban`, `adapter: Ecto.Adapters.Postgres`.

`test/support/test_steps.ex` — Four test step modules implementing `Hephaestus.Steps.Step`:
- `PassStep`: events `[:done]`, execute returns `{:ok, :done}`
- `AsyncStep`: events `[:timeout, :resumed]`, execute returns `{:async}`
- `FailStep`: events `[:done]`, execute returns `{:error, :forced_failure}`
- `PassWithContextStep`: events `[:done]`, execute returns `{:ok, :done, %{processed: true}}`

`test/support/test_workflows.ex` — Two test workflows using `use Hephaestus.Workflow`:
- `LinearWorkflow`: start -> PassStep, transit(PassStep, :done) -> Done
- `AsyncWorkflow`: start -> AsyncStep, transit(AsyncStep, :resumed) -> Done

### Test migrations

- `20260407000000_create_workflow_instances.exs` — calls `HephaestusEcto.Migration.up/0` in `change/0`
- `20260407000001_create_oban_jobs.exs` — calls `Oban.Migration.up/0` in `change/0`
- `20260407000002_create_step_results.exs` — calls `HephaestusOban.Migration.up/0` in `up/0` and `HephaestusOban.Migration.down/0` in `down/0`

### test_helper.exs

```elixir
{:ok, _} = HephaestusOban.TestRepo.start_link()
{:ok, _} = Oban.start_link(Application.fetch_env!(:hephaestus_oban, Oban))
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(HephaestusOban.TestRepo, :manual)
```

### Verification

Run `mix deps.get && mix compile` — must succeed with no errors.

## Done when

- [ ] `mix deps.get` succeeds
- [ ] `mix compile` succeeds with no errors
- [ ] All test support modules compile
- [ ] Config files exist and are correctly structured
- [ ] Test migrations exist (step_results migration can reference module that doesn't exist yet — it will compile once task-002 is done)
