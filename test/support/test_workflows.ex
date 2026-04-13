defmodule HephaestusOban.Test.LinearWorkflow do
  use Hephaestus.Workflow, unique: [key: "testoban"]

  @impl true
  def start, do: HephaestusOban.Test.PassStep

  @impl true
  def transit(HephaestusOban.Test.PassStep, :done, _ctx), do: Hephaestus.Steps.Done
end

defmodule HephaestusOban.Test.AsyncWorkflow do
  use Hephaestus.Workflow, unique: [key: "testoban"]

  @impl true
  def start, do: HephaestusOban.Test.AsyncStep

  @impl true
  def transit(HephaestusOban.Test.AsyncStep, :timeout, _ctx), do: Hephaestus.Steps.Done
  @impl true
  def transit(HephaestusOban.Test.AsyncStep, :resumed, _ctx), do: Hephaestus.Steps.Done
end

defmodule HephaestusOban.Test.TaggedWorkflow do
  use Hephaestus.Workflow,
    tags: ["onboarding", "growth"],
    metadata: %{"team" => "growth"},
    unique: [key: "testoban"]

  @impl true
  def start, do: HephaestusOban.Test.PassStep

  @impl true
  def transit(HephaestusOban.Test.PassStep, :done, _ctx), do: Hephaestus.Steps.Done
end

defmodule HephaestusOban.Test.VersionedWorkflow do
  use Hephaestus.Workflow, version: 3, unique: [key: "testoban"]

  @impl true
  def start, do: HephaestusOban.Test.PassStep

  @impl true
  def transit(HephaestusOban.Test.PassStep, :done, _ctx), do: Hephaestus.Steps.Done
end
