# Workflow Tags & Metadata (Core)

**Date:** 2026-04-07
**Status:** Approved
**Package:** `hephaestus` (core)

## Problem

Workflow modules have no way to declare custom tags or metadata at definition time. Runner adapters (Oban, Local, future) have no standardized way to access workflow-level labels for observability, filtering, or telemetry.

## Solution

Extend the `use Hephaestus.Workflow` macro to accept optional `tags` and `metadata` options and generate runtime accessor functions.

## Design

### Macro change: `Hephaestus.Workflow.__using__/1`

Currently ignores options (`_opts`). Change to accept and process `tags` and `metadata`:

```elixir
defmacro __using__(opts) do
  tags = Keyword.get(opts, :tags, [])
  metadata = Keyword.get(opts, :metadata, %{})

  quote do
    @behaviour Hephaestus.Core.Workflow
    Module.register_attribute(__MODULE__, unquote(@dynamic_edges_attr), accumulate: true)
    Module.register_attribute(__MODULE__, :targets, persist: false)
    @on_definition Hephaestus.Workflow
    @before_compile Hephaestus.Workflow

    @doc false
    def __tags__, do: unquote(tags)
    @doc false
    def __metadata__, do: unquote(Macro.escape(metadata))
  end
end
```

### Developer API

```elixir
defmodule MyApp.Workflows.OnboardFlow do
  use Hephaestus.Workflow,
    tags: ["onboarding", "growth"],
    metadata: %{"team" => "growth"}

  @impl true
  def start, do: MyApp.Steps.ValidateUser
  # ...
end
```

### Generated functions

- `__tags__/0` — returns the list of tags (default: `[]`)
- `__metadata__/0` — returns the metadata map (default: `%{}`)

These are generic and runner-agnostic. Any adapter can call `workflow_module.__tags__()` and `workflow_module.__metadata__()` at runtime.

### Compile-time validation

The macro validates inputs before generating code:
- `tags` must be a list of strings. Raises `CompileError` otherwise.
- `metadata` must be a map. Raises `CompileError` otherwise.

### Compatibility

- Zero breaking changes: both options default to empty values
- Existing workflows without options continue to compile and work identically
- Runner adapters can detect availability via `function_exported?(workflow_module, :__tags__, 0)`
