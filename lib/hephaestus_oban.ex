defmodule HephaestusOban do
  @moduledoc """
  Oban-backed runtime support for executing Hephaestus workflows with durable jobs,
  resumable async steps, and persisted step results.

  ## Observability

  All Oban jobs created by this adapter are automatically tagged with workflow metadata,
  enabling filtering in Oban Web by workflow type, execution instance, and step.

  Define tags and metadata on your workflow:

      defmodule MyApp.Workflows.OnboardFlow do
        use Hephaestus.Workflow,
          tags: ["onboarding", "growth"],
          metadata: %{"team" => "growth"}

        # ...
      end

  Every job will have:

    * `meta.heph_workflow` — workflow short name in snake_case (e.g., `"onboard_flow"`)
    * `meta.instance_id` — workflow execution UUID
    * `meta.workflow_version` — workflow revision number (e.g., `2`)
    * `meta.step` — step short name when applicable (e.g., `"validate_user"`)
    * `tags` — workflow short name plus any custom tags

  See `HephaestusOban.JobMetadata` for details on how metadata is built.
  """
end
