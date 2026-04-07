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

    meta = Map.merge(workflow_meta, system_meta)
    tags = Enum.uniq([workflow_name | workflow_tags])

    [meta: meta, tags: tags]
  end

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
