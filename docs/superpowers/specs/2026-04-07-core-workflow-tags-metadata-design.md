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

  validate_tags!(tags)
  validate_metadata!(metadata)

  quote do
    @behaviour Hephaestus.Core.Workflow
    Module.register_attribute(__MODULE__, unquote(@dynamic_edges_attr), accumulate: true)
    Module.register_attribute(__MODULE__, :targets, persist: false)
    @on_definition Hephaestus.Workflow
    @before_compile Hephaestus.Workflow

    @doc false
    def __tags__, do: unquote(tags)
    @doc false
    # Macro.escape/1 is required for the map — lists of strings are valid AST
    # literals and don't need escaping.
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

Validation runs at macro expansion time, **before** generating code. Invalid inputs produce clear `CompileError` messages pointing to the offending workflow module.

```elixir
defp validate_tags!(tags) do
  unless is_list(tags) and Enum.all?(tags, &is_binary/1) do
    raise CompileError,
      description: "expected :tags to be a list of strings, got: #{inspect(tags)}"
  end
end

defp validate_metadata!(metadata) do
  unless is_map(metadata) do
    raise CompileError,
      description: "expected :metadata to be a map, got: #{inspect(metadata)}"
  end

  unless Enum.all?(metadata, fn {k, _v} -> is_binary(k) end) do
    raise CompileError,
      description:
        "expected :metadata keys to be strings (atom keys would lose identity " <>
          "after JSON round-tripping in adapters like Oban), got: #{inspect(metadata)}"
  end

  unless json_safe_values?(metadata) do
    raise CompileError,
      description:
        "expected :metadata values to be JSON-safe (strings, numbers, booleans, " <>
          "or nested maps/lists of the same), got: #{inspect(metadata)}"
  end
end

defp json_safe_values?(map) when is_map(map) do
  Enum.all?(map, fn {_k, v} -> json_safe_value?(v) end)
end

defp json_safe_value?(v) when is_binary(v), do: true
defp json_safe_value?(v) when is_number(v), do: true
defp json_safe_value?(v) when is_boolean(v), do: true
defp json_safe_value?(v) when is_nil(v), do: true
defp json_safe_value?(v) when is_list(v), do: Enum.all?(v, &json_safe_value?/1)
defp json_safe_value?(v) when is_map(v), do: json_safe_values?(v)
defp json_safe_value?(_), do: false
```

**Rationale for JSON-safety check:** Metadata is designed for serialized observability (Oban Web, telemetry, logging). Allowing arbitrary Elixir terms (functions, PIDs, refs) would compile fine but fail at runtime when the Oban adapter serializes to JSONB. Catching this at compile time prevents a class of subtle runtime errors.

**Rationale for string-key enforcement:** Atom keys in metadata (e.g., `%{team: "growth"}`) would lose their identity after JSON round-tripping — `team` becomes `"team"`. Enforcing string keys at definition time ensures the developer sees exactly what adapters will store.

### Compatibility

- Zero breaking changes: both options default to empty values
- Existing workflows without options continue to compile and work identically
- Runner adapters can detect availability via `function_exported?(workflow_module, :__tags__, 0)`
