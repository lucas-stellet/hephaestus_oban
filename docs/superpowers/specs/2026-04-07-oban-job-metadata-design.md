# Oban Job Metadata & Tags for Workflow Observability

**Date:** 2026-04-07
**Status:** Approved
**Package:** `hephaestus_oban`
**Depends on:** [Core Workflow Tags & Metadata](2026-04-07-core-workflow-tags-metadata-design.md)

## Problem

When viewing Hephaestus workflow executions in the Oban Web UI, all jobs appear as generic `AdvanceWorker` and `ExecuteStepWorker` entries. There is no way to:
- Filter jobs by workflow type (e.g., "show me all OnboardFlow jobs")
- Filter jobs by specific execution (e.g., "show me all jobs for instance CBD700...")
- See which step a job relates to without inspecting the args
- Use custom developer-defined metadata for grouping

The `META` field on all jobs is currently `%{}` (empty).

## Solution

Automatically populate Oban job `meta` and `tags` fields using the workflow's `__tags__/0` and `__metadata__/0` (provided by the core macro), plus auto-derived workflow name, instance ID, and step name.

## Design

### 1. `JobMetadata` helper module

New module `HephaestusOban.JobMetadata` centralizes meta/tags construction and workflow module resolution:

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
      %{"heph_workflow" => workflow_name, "instance_id" => instance_id}
      |> maybe_put("step", step_ref && short_step_name(step_ref))

    # System keys take precedence over custom metadata
    meta = Map.merge(workflow_meta, system_meta)

    tags = Enum.uniq([workflow_name | workflow_tags])

    [meta: meta, tags: tags]
  end

  @doc """
  Resolves a workflow module atom from the string stored in job args.

  The string is always the `to_string/1` form of the module atom
  (e.g., `"Elixir.MyApp.Workflows.OnboardFlow"`).

  Uses `String.to_existing_atom/1` — safe because workflow modules are always
  compiled and loaded before any job referencing them can execute.
  """
  @spec resolve_workflow(String.t()) :: module()
  def resolve_workflow(workflow_string) when is_binary(workflow_string) do
    String.to_existing_atom(workflow_string)
  end

  # Takes the last segment of a module name and underscores it.
  # MyApp.Workflows.OnboardFlow -> "onboard_flow"
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

**Name conversion:** `Module.split/1 |> List.last/1 |> Macro.underscore/1` — extracts only the terminal segment. Matches the existing `context_key_for/1` pattern in the core.

**Short name collision:** Two workflows with the same terminal name (e.g., `MyApp.Workflows.Import` and `Other.Workflows.Import`) produce the same short name `"import"`. This is a known limitation — Oban Web filters by `tags:import` or `meta.heph_workflow:import` will match both. The full module string in `job.args["workflow"]` provides precise disambiguation via SQL queries. **Recommendation:** use unique terminal names across the application.

**Merge precedence:** System keys (`heph_workflow`, `instance_id`, `step`) always win over custom metadata.

### 2. Workflow propagation via args

All jobs include `"workflow"` in their args to propagate the workflow module without extra DB lookups:

```elixir
%{
  "instance_id" => instance_id,
  "config_key" => config_key,
  "workflow" => to_string(workflow_module)
}
```

The `"workflow"` value is the full `to_string(module)` form (e.g., `"Elixir.MyApp.Workflows.OnboardFlow"`) for reliable `String.to_existing_atom/1` round-tripping via `JobMetadata.resolve_workflow/1`. The human-friendly short name lives only in `meta` under the key `"heph_workflow"` (prefixed to avoid ambiguity with the full module string in args).

This does not affect unique constraints (which use `keys: [:instance_id]` and `keys: [:instance_id, :step_ref]`).

#### Before / after args for each worker

**AdvanceWorker** (from `runner.ex:start_instance`, `execute_step_worker.ex:insert_result_and_advance`, `resume_worker.ex:insert_result_and_advance`, `failure_handler.ex:handle_event`):

```elixir
# Before
%{"instance_id" => instance_id, "config_key" => config.key}
# After
%{"instance_id" => instance_id, "config_key" => config.key, "workflow" => to_string(workflow_module)}
```

**ExecuteStepWorker** (from `advance_worker.ex:enqueue_execute_step`):

```elixir
# Before
%{"instance_id" => instance_id, "config_key" => config.key, "step_ref" => to_string(step_module)}
# After
%{"instance_id" => instance_id, "config_key" => config.key, "step_ref" => to_string(step_module), "workflow" => to_string(workflow_module)}
```

**ResumeWorker** (from `runner.ex:schedule_resume`, `runner.ex:insert_resume_job`):

```elixir
# Before
%{"instance_id" => instance_id, "step_ref" => to_string(step_ref), "event" => event, "config_key" => config.key}
# After
%{"instance_id" => instance_id, "step_ref" => to_string(step_ref), "event" => event, "config_key" => config.key, "workflow" => to_string(workflow_module)}
```

#### Workflow module resolution at each creation point

| Location | `workflow_module` source | Conversion needed? |
|---|---|---|
| `runner.ex:start_instance` | function param (atom) | No |
| `advance_worker.ex:enqueue_execute_step` | `instance.workflow` (atom) | No |
| `execute_step_worker.ex:insert_result_and_advance` | `job.args["workflow"]` (string) | Yes — `JobMetadata.resolve_workflow/1` |
| `resume_worker.ex:insert_result_and_advance` | `job.args["workflow"]` (string) | Yes — `JobMetadata.resolve_workflow/1` |
| `failure_handler.ex:handle_event` | `job.args["workflow"]` (string) | Yes — `JobMetadata.resolve_workflow/1` |
| `runner.ex:schedule_resume` | `instance.workflow` (atom) | No |
| `runner.ex:insert_resume_job` | `instance.workflow` (atom) | No |

Locations that already have the atom pass it directly to `JobMetadata.build/3`. Locations that receive the string from a previous job's args call `JobMetadata.resolve_workflow/1` first.

### 3. Affected job creation points

| Location | Worker Created | `workflow` source | `step_ref` source |
|---|---|---|---|
| `runner.ex:start_instance` | AdvanceWorker | function param | none (kick-off) |
| `advance_worker.ex:enqueue_execute_step` | ExecuteStepWorker | `instance.workflow` | function param |
| `execute_step_worker.ex:insert_result_and_advance` | AdvanceWorker | `job.args["workflow"]` | `job.args["step_ref"]` |
| `resume_worker.ex:insert_result_and_advance` | AdvanceWorker | `job.args["workflow"]` | `job.args["step_ref"]` |
| `failure_handler.ex:handle_event` | AdvanceWorker | `job.args["workflow"]` | `job.args["step_ref"]` |
| `runner.ex:schedule_resume` | ResumeWorker | `instance.workflow` | function param |
| `runner.ex:insert_resume_job` | ResumeWorker | `instance.workflow` | function param |

#### Merge pattern (consistent at all creation points)

`JobMetadata.build/3` returns a keyword list `[meta: map(), tags: [String.t()]]`. Merge it into the `Oban.Job.new/2` opts:

```elixir
# Example: enqueue_execute_step (AdvanceWorker already has workflow_module as atom)
defp enqueue_execute_step(config, instance_id, workflow_module, step_module) do
  retry = RetryConfig.resolve(step_module, workflow_module)
  job_meta = JobMetadata.build(workflow_module, instance_id, step_ref: step_module)

  args = %{
    "instance_id" => instance_id,
    "config_key" => config.key,
    "step_ref" => to_string(step_module),
    "workflow" => to_string(workflow_module)
  }

  changeset =
    Oban.Job.new(
      args,
      [queue: :hephaestus, worker: HephaestusOban.ExecuteStepWorker, max_attempts: retry.max_attempts]
      ++ job_meta
    )

  Oban.insert(config.oban, changeset)
  :ok
end
```

The same `[...opts] ++ job_meta` pattern applies to all 7 creation points. For `Worker.new/2` calls (e.g., `AdvanceWorker.new(args)`), pass `job_meta` as the second argument: `AdvanceWorker.new(args, job_meta)`.

#### FailureHandler detail

The current `handle_event/4` only extracts `instance_id` and `config_key`. It must be updated to also extract `step_ref` and `workflow` from the discarded ExecuteStepWorker's args:

```elixir
def handle_event([:oban, :job, :stop], _measure, %{job: job, state: :discard}, _config) do
  if job.worker == @execute_step_worker do
    config = resolve_config(job)

    %{
      "instance_id" => instance_id,
      "config_key" => config_key,
      "step_ref" => step_ref,
      "workflow" => workflow_string
    } = job.args

    workflow_module = JobMetadata.resolve_workflow(workflow_string)
    job_meta = JobMetadata.build(workflow_module, instance_id, step_ref: step_ref)

    %{
      "instance_id" => instance_id,
      "config_key" => config_key,
      "workflow" => workflow_string
    }
    |> HephaestusOban.AdvanceWorker.new(job_meta)
    |> then(&Oban.insert(config.oban, &1))
  else
    :ok
  end
end
```

Note: `step_ref` is passed to `JobMetadata.build/3` so the AdvanceWorker's meta records which step's failure triggered this advance. The `workflow_string` is forwarded as-is to the new AdvanceWorker's args (no need to convert back to string).

### 4. Resulting Oban Web experience

**ExecuteStepWorker job:**
```elixir
tags: ["onboard_flow", "onboarding", "growth"]
meta: %{
  "heph_workflow" => "onboard_flow",
  "instance_id" => "CBD700A6-B048-45CC-BDE9-7F8E200EFCD5",
  "step" => "validate_user",
  "team" => "growth"
}
```

**AdvanceWorker job (after step completes):**
```elixir
tags: ["onboard_flow", "onboarding", "growth"]
meta: %{
  "heph_workflow" => "onboard_flow",
  "instance_id" => "CBD700A6-B048-45CC-BDE9-7F8E200EFCD5",
  "step" => "validate_user",
  "team" => "growth"
}
```

**AdvanceWorker job (initial kick-off):**
```elixir
tags: ["onboard_flow", "onboarding", "growth"]
meta: %{
  "heph_workflow" => "onboard_flow",
  "instance_id" => "CBD700A6-B048-45CC-BDE9-7F8E200EFCD5",
  "team" => "growth"
}
```

Note: `"heph_workflow"` is prefixed to avoid ambiguity with `args["workflow"]` (which stores the full module string `"Elixir.MyApp.Workflows.OnboardFlow"`). The meta key holds the human-friendly short name for Oban Web display; the args key holds the full module string for code-level resolution.

**Oban Web filters:**
```
tags:onboard_flow                  -> all jobs for this workflow type
meta.instance_id:CBD700...         -> all jobs for a specific execution
meta.step:validate_user            -> all executions of a specific step
meta.team:growth                   -> custom developer filter
meta.heph_workflow:onboard_flow    -> alternative to tag filter
```

## Testing

### Unit tests: `JobMetadata`

```elixir
describe "build/3" do
  test "returns system meta and tags for a workflow without custom tags/metadata" do
    assert [meta: meta, tags: tags] =
             JobMetadata.build(PlainWorkflow, "abc-123")

    assert meta == %{"heph_workflow" => "plain_workflow", "instance_id" => "abc-123"}
    assert tags == ["plain_workflow"]
  end

  test "merges custom tags and metadata from workflow" do
    assert [meta: meta, tags: tags] =
             JobMetadata.build(TaggedWorkflow, "abc-123", step_ref: MyApp.Steps.ValidateUser)

    assert meta["team"] == "growth"
    assert meta["step"] == "validate_user"
    assert "onboarding" in tags
  end

  test "system keys take precedence over custom metadata" do
    # Workflow declares metadata: %{"heph_workflow" => "custom"}
    assert [meta: meta, tags: _] = JobMetadata.build(ConflictingWorkflow, "abc-123")
    assert meta["heph_workflow"] == "conflicting_workflow"  # system wins
  end
end

describe "resolve_workflow/1" do
  test "converts full module string to existing atom" do
    assert JobMetadata.resolve_workflow("Elixir.MyApp.Workflows.OnboardFlow") ==
             MyApp.Workflows.OnboardFlow
  end
end
```

### Integration tests: meta/tags propagation

```elixir
test "start_instance creates AdvanceWorker with correct meta and tags" do
  {:ok, instance_id} = Runner.start_instance(OnboardFlow, %{}, opts)

  assert [job] = all_enqueued(worker: AdvanceWorker)
  assert job.args["workflow"] == "Elixir.MyApp.Workflows.OnboardFlow"
  assert "onboard_flow" in job.tags
  assert job.meta["heph_workflow"] == "onboard_flow"
  assert job.meta["instance_id"] == instance_id
  refute Map.has_key?(job.meta, "step")  # kick-off has no step
end

test "meta/tags propagate through advance -> execute -> advance chain" do
  {:ok, instance_id} = Runner.start_instance(OnboardFlow, %{user_id: 1}, opts)

  # Drain AdvanceWorker — should enqueue ExecuteStepWorker
  assert :ok = perform_job(AdvanceWorker, %{"instance_id" => instance_id, ...})

  assert [exec_job] = all_enqueued(worker: ExecuteStepWorker)
  assert exec_job.args["workflow"] == "Elixir.MyApp.Workflows.OnboardFlow"
  assert exec_job.meta["step"] == "validate_user"
  assert "onboard_flow" in exec_job.tags

  # Drain ExecuteStepWorker — should enqueue next AdvanceWorker
  assert :ok = perform_job(ExecuteStepWorker, exec_job.args)

  assert [advance_job] = all_enqueued(worker: AdvanceWorker)
  assert advance_job.args["workflow"] == "Elixir.MyApp.Workflows.OnboardFlow"
  assert advance_job.meta["step"] == "validate_user"
end
```

## Compatibility

- Zero breaking changes to existing job creation
- `function_exported?/3` check in `JobMetadata` makes it resilient to workflows compiled before the core change
- Bump `hephaestus` dependency to require core version with `__tags__/0` and `__metadata__/0`
- Note: Oban Web (Pro) is required for the filtering UI, but meta/tags on job records are useful regardless for queries, telemetry, and logging
