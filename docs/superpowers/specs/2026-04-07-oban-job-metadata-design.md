# Oban Job Metadata & Tags for Workflow Observability

**Date:** 2026-04-07
**Status:** Approved

## Problem

When viewing Hephaestus workflow executions in the Oban Web UI, all jobs appear as generic `AdvanceWorker` and `ExecuteStepWorker` entries. There is no way to:
- Filter jobs by workflow type (e.g., "show me all OnboardFlow jobs")
- Filter jobs by specific execution (e.g., "show me all jobs for instance CBD700...")
- See which step a job relates to without inspecting the args
- Use custom developer-defined metadata for grouping

The `META` field on all jobs is currently `%{}` (empty).

## Solution

Add `tags` and `metadata` support at the workflow definition level (core `Hephaestus.Workflow` macro) and automatically populate Oban job `meta` and `tags` fields in `hephaestus_oban`.

## Design

### 1. Core Change: `Hephaestus.Workflow` macro

The `__using__/1` macro accepts optional `tags` and `metadata` opts and generates accessor functions:

```elixir
defmodule MyApp.Workflows.OnboardFlow do
  use Hephaestus.Workflow,
    tags: ["onboarding", "growth"],
    metadata: %{"team" => "growth"}

  @impl true
  def start, do: MyApp.Steps.ValidateUser

  @impl true
  def transit(MyApp.Steps.ValidateUser, :valid, _ctx), do: MyApp.Steps.ProcessPayment
  # ...
end
```

The macro generates:
- `__tags__/0` returning `["onboarding", "growth"]` (default: `[]`)
- `__metadata__/0` returning `%{"team" => "growth"}` (default: `%{}`)

These are generic (no Oban-specific naming) and available to any runner.

### 2. `hephaestus_oban` — `JobMetadata` helper

New module `HephaestusOban.JobMetadata` centralizes meta/tags construction:

```elixir
defmodule HephaestusOban.JobMetadata do
  @moduledoc false

  @spec build(module(), String.t(), keyword()) :: [meta: map(), tags: [String.t()]]
  def build(workflow_module, instance_id, opts \\ []) do
    step_ref = Keyword.get(opts, :step_ref)

    workflow_name = short_name(workflow_module)
    workflow_tags = safe_call(workflow_module, :__tags__, [])
    workflow_meta = safe_call(workflow_module, :__metadata__, %{})

    system_meta =
      %{"workflow" => workflow_name, "instance_id" => instance_id}
      |> maybe_put("step", step_ref && short_step_name(step_ref))

    # System keys take precedence over custom metadata
    meta = Map.merge(workflow_meta, system_meta)

    tags = Enum.uniq([workflow_name | workflow_tags])

    [meta: meta, tags: tags]
  end

  # Takes the last segment of a module name and underscores it.
  # MyApp.Workflows.OnboardFlow -> "onboard_flow"
  # Uses Module.split/1 + List.last/1 + Macro.underscore/1 to extract
  # only the terminal segment (not the full namespace path).
  defp short_name(module) when is_atom(module) do
    module |> Module.split() |> List.last() |> Macro.underscore()
  end

  # Accepts both atom and string step refs.
  # MyApp.Steps.ValidateUser -> "validate_user"
  # "Elixir.MyApp.Steps.ValidateUser" -> "validate_user"
  defp short_step_name(step_ref) when is_atom(step_ref) do
    step_ref |> Module.split() |> List.last() |> Macro.underscore()
  end

  defp short_step_name(step_ref) when is_binary(step_ref) do
    step_ref |> String.split(".") |> List.last() |> Macro.underscore()
  end

  defp safe_call(module, func, default) do
    if function_exported?(module, func, 0),
      do: apply(module, func, []),
      else: default
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
```

**Name conversion algorithm:** `Module.split/1 |> List.last/1 |> Macro.underscore/1` — extracts only the terminal module segment, not the full namespace. This matches the existing `context_key_for/1` pattern in the core. Note: two workflows in different namespaces with the same terminal name would produce the same short name. This is acceptable since the full module string is available in `job.args["workflow"]` for disambiguation.

**`step_ref` type:** Accepts both atoms (when the module is in scope) and strings (when read from `job.args["step_ref"]`).

**Merge precedence:** System-generated keys (`workflow`, `instance_id`, `step`) always take precedence over custom metadata to prevent accidental overwrites.

### 3. Workflow propagation via args

All jobs include `"workflow"` in their args to propagate the workflow module without extra DB lookups:

```elixir
%{
  "instance_id" => instance_id,
  "config_key" => config_key,
  "workflow" => to_string(workflow_module)
}
```

This does not affect unique constraints (which use `keys: [:instance_id]` and `keys: [:instance_id, :step_ref]`). The `"workflow"` arg value is the full `to_string(module)` form (e.g., `"Elixir.MyApp.Workflows.OnboardFlow"`) for reliable `String.to_existing_atom/1` round-tripping. The human-friendly short name lives only in `meta`.

### 4. Affected job creation points

| Location | Worker Created | `workflow` source | `step_ref` source |
|---|---|---|---|
| `runner.ex:start_instance` | AdvanceWorker | function param | none (kick-off) |
| `advance_worker.ex:enqueue_execute_step` | ExecuteStepWorker | `instance.workflow` | function param |
| `execute_step_worker.ex:insert_result_and_advance` | AdvanceWorker | `job.args["workflow"]` | `job.args["step_ref"]` |
| `resume_worker.ex:insert_result_and_advance` | AdvanceWorker | `job.args["workflow"]` | `job.args["step_ref"]` |
| `failure_handler.ex:handle_event` | AdvanceWorker | `job.args["workflow"]` | `job.args["step_ref"]` |
| `runner.ex:schedule_resume` | ResumeWorker | `instance.workflow` | function param |
| `runner.ex:insert_resume_job` | ResumeWorker | `instance.workflow` | function param |

### 5. Resulting Oban Web experience

**ExecuteStepWorker job:**
```elixir
tags: ["onboard_flow", "onboarding", "growth"]
meta: %{
  "workflow" => "onboard_flow",
  "instance_id" => "CBD700A6-B048-45CC-BDE9-7F8E200EFCD5",
  "step" => "validate_user",
  "team" => "growth"
}
```

**AdvanceWorker job (after a step completes):**
```elixir
tags: ["onboard_flow", "onboarding", "growth"]
meta: %{
  "workflow" => "onboard_flow",
  "instance_id" => "CBD700A6-B048-45CC-BDE9-7F8E200EFCD5",
  "step" => "validate_user",
  "team" => "growth"
}
```

**AdvanceWorker job (initial kick-off):**
```elixir
tags: ["onboard_flow", "onboarding", "growth"]
meta: %{
  "workflow" => "onboard_flow",
  "instance_id" => "CBD700A6-B048-45CC-BDE9-7F8E200EFCD5",
  "team" => "growth"
}
```

**Oban Web filters:**
```
tags:onboard_flow             -> all jobs for this workflow type
meta.instance_id:CBD700...    -> all jobs for a specific execution
meta.step:validate_user       -> all executions of a specific step
meta.team:growth              -> custom developer filter
```

## Packages affected and release sequence

1. **`hephaestus` (core)** — `Hephaestus.Workflow.__using__/1`: accept `tags`/`metadata` opts, generate `__tags__/0` and `__metadata__/0`. **Must be released first.**
2. **`hephaestus_oban`** — new `JobMetadata` module + changes to all job creation points + `"workflow"` in args. Bump `hephaestus` dependency to require the new core version.

## Validation

The core macro should validate inputs at compile time:
- `tags` must be a list of strings (or atoms convertible to strings). Raise `CompileError` otherwise.
- `metadata` must be a map. Raise `CompileError` otherwise.

## Compatibility

- Zero breaking changes: `tags` defaults to `[]`, `metadata` defaults to `%{}`
- Existing workflows without opts continue to work (get auto-generated workflow name tag only)
- `function_exported?/3` check in `JobMetadata` makes it resilient to workflows compiled before the core change
- Note: Oban Web (Pro) is required for the filtering UI, but the meta/tags on job records are useful regardless for queries, telemetry, and logging
