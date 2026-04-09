# Versionamento de Workflows — hephaestus_oban

**Data:** 2026-04-08
**Status:** Implementado
**Spec principal:** `hephaestus_core/docs/superpowers/specs/2026-04-08-workflow-versioning-design.md`

## Contexto

O hephaestus_core está adicionando versionamento de workflows. Cada versão é um módulo Elixir separado (ex: `CreateUser.V1`, `CreateUser.V2`). A `Instance` passa a ter um campo `workflow_version` (integer, default 1). A resolução de versão acontece no core — o oban runner recebe o módulo concreto já resolvido.

Para o oban, três mudanças são necessárias:
1. Sistema de migrations versionadas (padrão Oban)
2. `workflow_version` nos job args e na tabela step_results
3. `workflow_version` no JobMetadata para observabilidade

---

## 1. Padrão de Migration Versionada

Refatorar o `migration.ex` existente em módulos versionados, seguindo o mesmo padrão do Oban.

### Estrutura de arquivos

```
lib/hephaestus_oban/
  migration.ex                    # API pública (refatorada)
  migrations/
    postgres.ex                   # Orquestrador
    postgres/
      v01.ex                      # Tabela step_results inicial
      v02.ex                      # Adiciona coluna metadata_updates (atualmente add_metadata_updates/0)
      v03.ex                      # Adiciona coluna workflow_version
```

### API pública

```elixir
# Instalação nova — roda todas as versões
defmodule MyApp.Repo.Migrations.AddHephaestusOban do
  use Ecto.Migration

  def up, do: HephaestusOban.Migration.up()
  def down, do: HephaestusOban.Migration.down()
end

# Upgrade incremental
defmodule MyApp.Repo.Migrations.UpgradeHephaestusObanToV3 do
  use Ecto.Migration

  def up, do: HephaestusOban.Migration.up(version: 3)
  def down, do: HephaestusOban.Migration.down(version: 2)
end
```

### V01 — step_results inicial (extraído do migration.ex atual)

Cria tabela `hephaestus_step_results` com `instance_id`, `step_ref`, `event`, `context_updates`, `processed`, `inserted_at` e índices.

### V02 — metadata_updates (o que atualmente é `add_metadata_updates/0`)

```elixir
defmodule HephaestusOban.Migrations.Postgres.V02 do
  def up(%{prefix: prefix}) do
    alter table(:hephaestus_step_results, prefix: prefix) do
      add_if_not_exists :metadata_updates, :map, default: %{}
    end
  end

  def down(%{prefix: prefix}) do
    alter table(:hephaestus_step_results, prefix: prefix) do
      remove_if_exists :metadata_updates, :map
    end
  end
end
```

### V03 — workflow_version

```elixir
defmodule HephaestusOban.Migrations.Postgres.V03 do
  def up(%{prefix: prefix}) do
    alter table(:hephaestus_step_results, prefix: prefix) do
      add_if_not_exists :workflow_version, :integer, null: false, default: 1
    end
  end

  def down(%{prefix: prefix}) do
    alter table(:hephaestus_step_results, prefix: prefix) do
      remove_if_exists :workflow_version, :integer
    end
  end
end
```

### Orquestrador

```elixir
defmodule HephaestusOban.Migrations.Postgres do
  @initial_version 1
  @current_version 3

  def up(opts) do
    opts = with_defaults(opts, @current_version)
    initial = migrated_version(opts)

    cond do
      initial == 0 -> change(@initial_version..opts.version, :up, opts)
      initial < opts.version -> change((initial + 1)..opts.version, :up, opts)
      true -> :ok
    end
  end

  def down(opts) do
    opts = with_defaults(opts, @initial_version)
    current = migrated_version(opts)

    cond do
      current > opts.version -> change(current..(opts.version + 1)//-1, :down, opts)
      true -> :ok
    end
  end

  def migrated_version(opts) do
    # Lê a versão de: COMMENT ON TABLE hephaestus_step_results
    # Retorna integer ou 0 se não encontrado
  end

  defp record_version(%{prefix: prefix}, version) do
    execute "COMMENT ON TABLE #{prefix}.hephaestus_step_results IS '#{version}'"
  end
end
```

---

## 2. Job Args — todos os workers incluem workflow_version

```elixir
# AdvanceWorker, ExecuteStepWorker, ResumeWorker
%{
  "instance_id" => "uuid",
  "workflow" => "Elixir.MyApp.Workflows.CreateUser.V2",
  "workflow_version" => 2,
  "config_key" => "key",
  ...
}
```

A versão é resolvida **antes** do enqueue — o Oban runner recebe o módulo concreto, igual ao runner local. Na hora de executar o job, deserializa o módulo string → atom e a versão já está lá.

---

## 3. JobMetadata — observabilidade no Oban Web

```elixir
%{
  "heph_workflow" => "create_user",
  "workflow_version" => 2,
  "instance_id" => "uuid",
  ...
}
```

Permite queries no Oban dashboard/UI:

```elixir
# Jobs de CreateUser V1 que falharam
Oban.Job
|> where([j], fragment("args->>'workflow_version' = ?", "1"))
|> where([j], j.state == "discarded")
|> Repo.all()
```

---

## 4. Mudanças nos Workers

- `Runner.start_instance/3` — extrai `workflow_version` dos opts, inclui nos args do AdvanceWorker
- `ExecuteStepWorker` — propaga `workflow_version` nos args ao enfileirar AdvanceWorker
- `StepResults.insert/1` — persiste `workflow_version` na tabela
- `JobMetadata` — adiciona `workflow_version` ao meta do job

---

## 5. O que NÃO muda

- Mecanismo de advisory lock
- Lógica de advance/execute/resume (módulo já resolvido)
- Estrutura de queue/worker do Oban (mesmos 3 workers)

---

## Changelog

```markdown
## [Unreleased]

### Adicionado
- Sistema de migration versionada seguindo o padrão do Oban (V01, V02, V03, ...)
- `HephaestusOban.Migration.up/1` e `down/1` com tracking de versão
- Migration V03: coluna integer `workflow_version` em `hephaestus_step_results` (default: 1)
- `workflow_version` nos job args de todos os workers (AdvanceWorker, ExecuteStepWorker, ResumeWorker)
- `workflow_version` no JobMetadata para observabilidade no Oban Web

### Alterado
- `migration.ex` existente refatorado em módulos versionados (V01: inicial, V02: metadata_updates, V03: workflow_version)
- `StepResults.insert/1` persiste `workflow_version`
```

## Documentação

- Guia de upgrade para quem já tem hephaestus_oban instalado: rodar `HephaestusOban.Migration.up(version: 3)`
- Documentar `workflow_version` nos job args e no meta para queries no Oban Web
