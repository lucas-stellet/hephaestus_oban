defmodule HephaestusOban.StorageFiltersTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(HephaestusOban.TestRepo)
    repo = HephaestusOban.TestRepo
    storage_name = :"test_sf_storage_#{System.unique_integer([:positive])}"
    :ignore = HephaestusEcto.Storage.start_link(repo: repo, name: storage_name)
    %{repo: repo, storage_name: storage_name}
  end

  describe "storage query filters through the Oban storage layer" do
    test "queries by :id using business key instance ids", %{storage_name: storage_name} do
      target = build_instance()
      other = build_instance()

      :ok = HephaestusEcto.Storage.put(storage_name, target)
      :ok = HephaestusEcto.Storage.put(storage_name, other)

      results = HephaestusEcto.Storage.query(storage_name, id: target.id)

      assert Enum.map(results, & &1.id) == [target.id]
    end

    test "queries by :status_in across multiple runtime statuses", %{storage_name: storage_name} do
      pending = build_instance()
      running = persist_with_status(storage_name, build_instance(), :running)
      completed = persist_with_status(storage_name, build_instance(), :completed)

      :ok = HephaestusEcto.Storage.put(storage_name, pending)

      results =
        HephaestusEcto.Storage.query(storage_name, status_in: [:pending, :running])

      assert Enum.sort_by(results, & &1.id) |> Enum.map(& &1.id) ==
               Enum.sort([pending.id, running.id])

      refute Enum.any?(results, &(&1.id == completed.id))
    end

    test "queries by :workflow_version", %{storage_name: storage_name} do
      version_one = build_instance(workflow_version: 1)
      version_two = build_instance(workflow_version: 2)

      :ok = HephaestusEcto.Storage.put(storage_name, version_one)
      :ok = HephaestusEcto.Storage.put(storage_name, version_two)

      results = HephaestusEcto.Storage.query(storage_name, workflow_version: 2)

      assert Enum.map(results, & &1.id) == [version_two.id]
    end

    test "applies combined :id + :status_in + :workflow filters with AND semantics", %{
      storage_name: storage_name
    } do
      target = persist_with_status(storage_name, build_instance(), :running)
      _wrong_id = persist_with_status(storage_name, build_instance(), :running)
      _wrong_status = persist_with_status(storage_name, %{target | id: unique_id()}, :completed)

      _wrong_workflow =
        build_other_workflow_instance()
        |> then(&persist_with_status(storage_name, &1, :running))

      results =
        HephaestusEcto.Storage.query(storage_name,
          id: target.id,
          status_in: [:pending, :running],
          workflow: HephaestusOban.Test.LinearWorkflow
        )

      assert Enum.map(results, & &1.id) == [target.id]
    end
  end

  defp build_instance(opts \\ []) do
    workflow_version = Keyword.get(opts, :workflow_version, 1)

    Hephaestus.Core.Instance.new(
      HephaestusOban.Test.LinearWorkflow,
      workflow_version,
      %{some: "context"},
      unique_id()
    )
  end

  defp build_other_workflow_instance do
    Hephaestus.Core.Instance.new(
      HephaestusOban.Test.AsyncWorkflow,
      1,
      %{some: "context"},
      unique_id()
    )
  end

  defp persist_with_status(storage_name, instance, status) do
    instance = %{instance | status: status}
    :ok = HephaestusEcto.Storage.put(storage_name, instance)
    instance
  end

  defp unique_id do
    "testoban::filter#{System.unique_integer([:positive])}"
  end
end
