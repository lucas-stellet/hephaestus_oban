defmodule HephaestusOban.RetryConfig do
  @moduledoc false

  @default %{max_attempts: 5, backoff: :exponential, max_backoff: 60_000}

  def resolve(step_module, workflow_module) do
    cond do
      function_exported?(step_module, :retry_config, 0) ->
        step_module.retry_config()

      function_exported?(workflow_module, :default_retry_config, 0) ->
        workflow_module.default_retry_config()

      true ->
        @default
    end
  end

  def default, do: @default
end
