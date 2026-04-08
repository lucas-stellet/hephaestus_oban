defmodule HephaestusOban.JobMetadata do
  @moduledoc """
  Builds Oban job `meta` and `tags` from workflow module attributes.

  Every Oban job created by `HephaestusOban` is enriched with metadata that
  enables filtering in Oban Web. This module centralizes that logic so all
  workers produce consistent metadata.

  ## Auto-populated fields

  | Meta key | Source | Example |
  |----------|--------|---------|
  | `heph_workflow` | Last segment of workflow module, snake_cased | `"onboard_flow"` |
  | `instance_id` | Workflow execution UUID | `"CBD700A6-..."` |
  | `step` | Last segment of step module, snake_cased (when applicable) | `"validate_user"` |

  Custom tags and metadata defined via `use Hephaestus.Workflow` are merged in.
  System keys (`heph_workflow`, `instance_id`, `step`) always take precedence
  over custom metadata to prevent accidental overwrites.

  ## Name conversion

  Module names are shortened using `Module.split/1 |> List.last/1 |> Macro.underscore/1`,
  matching the `context_key_for/1` convention in the core. For example:

    * `MyApp.Workflows.OnboardFlow` → `"onboard_flow"`
    * `MyApp.Steps.ValidateUser` → `"validate_user"`
  """

  @doc """
  Builds a keyword list of Oban job options (`meta` and `tags`) for the given
  workflow module and instance.

  ## Options

    * `:step_ref` — the step module (atom) or stringified module name. When provided,
      a `"step"` key is added to `meta` with the snake_cased short name.
    * `:runtime_metadata` — a map of dynamic metadata accumulated from step executions.
      Merged after workflow metadata but before system keys.

  ## Examples

      iex> HephaestusOban.JobMetadata.build(MyApp.Workflows.OnboardFlow, "abc-123")
      [meta: %{"heph_workflow" => "onboard_flow", "instance_id" => "abc-123"}, tags: ["onboard_flow"]]

      iex> HephaestusOban.JobMetadata.build(MyApp.Workflows.OnboardFlow, "abc-123", step_ref: MyApp.Steps.ValidateUser)
      [meta: %{"heph_workflow" => "onboard_flow", "instance_id" => "abc-123", "step" => "validate_user"}, tags: ["onboard_flow"]]

  """
  @spec build(module(), String.t(), keyword()) :: [meta: map(), tags: [String.t()]]
  def build(workflow_module, instance_id, opts \\ []) do
    step_ref = Keyword.get(opts, :step_ref)
    runtime_meta = Keyword.get(opts, :runtime_metadata, %{})

    workflow_name = short_name(workflow_module)
    workflow_tags = safe_call(workflow_module, :__tags__, [])
    workflow_meta = safe_call(workflow_module, :__metadata__, %{})

    system_meta =
      %{"heph_workflow" => workflow_name, "instance_id" => instance_id}
      |> maybe_put("step", step_ref && short_step_name(step_ref))

    meta = workflow_meta |> Map.merge(runtime_meta) |> Map.merge(system_meta)
    tags = Enum.uniq([workflow_name | workflow_tags])

    [meta: meta, tags: tags]
  end

  @doc """
  Converts a workflow module string (from job args) back to the module atom.

  Uses `String.to_existing_atom/1` — safe because workflow modules are always
  compiled and loaded before any job referencing them can execute.
  """
  @spec resolve_workflow(String.t()) :: module()
  def resolve_workflow(workflow_string) when is_binary(workflow_string) do
    String.to_existing_atom(workflow_string)
  end

  defp short_name(module) when is_atom(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp short_step_name(step_ref) when is_atom(step_ref),
    do: step_ref |> Module.split() |> List.last() |> Macro.underscore()

  defp short_step_name(step_ref) when is_binary(step_ref),
    do: step_ref |> String.split(".") |> List.last() |> Macro.underscore()

  defp safe_call(module, func, default) do
    _ = Code.ensure_loaded(module)
    if function_exported?(module, func, 0), do: apply(module, func, []), else: default
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
