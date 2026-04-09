defmodule HephaestusOban.JobMetadataTest do
  use ExUnit.Case, async: true

  alias HephaestusOban.JobMetadata

  describe "build/3" do
    test "returns system meta and tags for a workflow without custom tags/metadata" do
      # LinearWorkflow has no __tags__/0 or __metadata__/0
      assert [meta: meta, tags: tags] =
               JobMetadata.build(HephaestusOban.Test.LinearWorkflow, "abc-123")

      assert meta == %{
               "heph_workflow" => "linear_workflow",
               "instance_id" => "abc-123",
               "workflow_version" => 1
             }

      assert tags == ["linear_workflow"]
    end

    test "merges custom tags and metadata from tagged workflow" do
      assert [meta: meta, tags: tags] =
               JobMetadata.build(HephaestusOban.Test.TaggedWorkflow, "abc-123")

      assert meta["team"] == "growth"
      assert meta["heph_workflow"] == "tagged_workflow"
      assert meta["instance_id"] == "abc-123"
      assert "onboarding" in tags
      assert "growth" in tags
      assert "tagged_workflow" in tags
    end

    test "includes step in meta when step_ref is provided (atom)" do
      assert [meta: meta, tags: _] =
               JobMetadata.build(
                 HephaestusOban.Test.LinearWorkflow,
                 "abc-123",
                 step_ref: HephaestusOban.Test.PassStep
               )

      assert meta["step"] == "pass_step"
    end

    test "includes step in meta when step_ref is provided (string)" do
      assert [meta: meta, tags: _] =
               JobMetadata.build(
                 HephaestusOban.Test.LinearWorkflow,
                 "abc-123",
                 step_ref: "Elixir.HephaestusOban.Test.PassStep"
               )

      assert meta["step"] == "pass_step"
    end

    test "omits step from meta when step_ref is nil" do
      assert [meta: meta, tags: _] =
               JobMetadata.build(HephaestusOban.Test.LinearWorkflow, "abc-123")

      refute Map.has_key?(meta, "step")
    end

    test "system keys take precedence over custom metadata" do
      # TaggedWorkflow has metadata: %{"team" => "growth"}
      # If it also had "heph_workflow" => "custom", system should win
      assert [meta: meta, tags: _] =
               JobMetadata.build(HephaestusOban.Test.TaggedWorkflow, "abc-123")

      assert meta["heph_workflow"] == "tagged_workflow"
    end

    test "deduplicates tags" do
      # If workflow_name matches one of the custom tags, no duplicates
      assert [meta: _, tags: tags] =
               JobMetadata.build(HephaestusOban.Test.TaggedWorkflow, "abc-123")

      assert tags == Enum.uniq(tags)
    end

    test "meta includes workflow_version from module's __version__/0" do
      assert [meta: meta, tags: _] =
               JobMetadata.build(HephaestusOban.Test.VersionedWorkflow, "abc-123")

      assert meta["workflow_version"] == 3
    end

    test "meta includes workflow_version defaulting to 1 for unversioned workflow" do
      assert [meta: meta, tags: _] =
               JobMetadata.build(HephaestusOban.Test.LinearWorkflow, "abc-123")

      assert meta["workflow_version"] == 1
    end
  end

  describe "resolve_workflow/1" do
    test "converts full module string to existing atom" do
      workflow_string = to_string(HephaestusOban.Test.LinearWorkflow)

      assert JobMetadata.resolve_workflow(workflow_string) ==
               HephaestusOban.Test.LinearWorkflow
    end

    test "raises for non-existing atom" do
      assert_raise ArgumentError, fn ->
        JobMetadata.resolve_workflow("Elixir.Totally.Fake.Module.That.Does.Not.Exist")
      end
    end
  end
end
