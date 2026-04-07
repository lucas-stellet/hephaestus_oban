defmodule HephaestusOban.Test.PassStep do
  @behaviour Hephaestus.Steps.Step

  @impl true
  def events, do: [:done]

  @impl true
  def execute(_instance, _config, _context), do: {:ok, :done}
end

defmodule HephaestusOban.Test.AsyncStep do
  @behaviour Hephaestus.Steps.Step

  @impl true
  def events, do: [:timeout, :resumed]

  @impl true
  def execute(_instance, _config, _context), do: {:async}
end

defmodule HephaestusOban.Test.FailStep do
  @behaviour Hephaestus.Steps.Step

  @impl true
  def events, do: [:done]

  @impl true
  def execute(_instance, _config, _context), do: {:error, :forced_failure}
end

defmodule HephaestusOban.Test.PassWithContextStep do
  @behaviour Hephaestus.Steps.Step

  @impl true
  def events, do: [:done]

  @impl true
  def execute(_instance, _config, _context), do: {:ok, :done, %{processed: true}}
end
