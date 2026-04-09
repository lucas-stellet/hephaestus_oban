defmodule HephaestusOban.Migrations.PostgresTest do
  use ExUnit.Case, async: false

  alias HephaestusOban.Migrations.Postgres
  alias HephaestusOban.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    %{opts: [prefix: "public", repo: TestRepo]}
  end

  describe "migrated_version/1" do
    test "returns 0 when the table comment is absent", %{opts: opts} do
      TestRepo.query!(
        "COMMENT ON TABLE hephaestus_step_results IS NULL",
        [],
        log: false
      )

      try do
        assert 0 = Postgres.migrated_version(opts)
      after
        TestRepo.query!(
          "COMMENT ON TABLE \"public\".hephaestus_step_results IS '#{Postgres.current_version()}'",
          [],
          log: false
        )
      end
    end

    test "returns correct version for a migrated database", %{opts: opts} do
      assert Postgres.migrated_version(opts) == Postgres.current_version()
    end

    test "returns 0 when table does not exist" do
      prefix = "migration_oban_test_#{System.unique_integer([:positive])}"
      TestRepo.query!("CREATE SCHEMA #{prefix}")

      try do
        assert 0 = Postgres.migrated_version(repo: TestRepo, prefix: prefix)
      after
        TestRepo.query!("DROP SCHEMA IF EXISTS #{prefix} CASCADE")
      end
    end
  end

  describe "up/1 idempotency" do
    test "calling up/1 when already at current version is a no-op", %{opts: opts} do
      assert :ok = Postgres.up(opts)
      assert Postgres.migrated_version(opts) == Postgres.current_version()
    end
  end

  describe "down/1 no-op" do
    test "returns :ok when target version is above the current version", %{opts: opts} do
      assert :ok = Postgres.down(Keyword.put(opts, :version, Postgres.current_version() + 1))
    end
  end

  describe "prefix validation" do
    test "rejects invalid prefix" do
      assert_raise ArgumentError, fn ->
        Postgres.up(prefix: "Robert'; DROP TABLE --", repo: TestRepo)
      end
    end

    test "rejects prefix with special characters" do
      assert_raise ArgumentError, fn ->
        Postgres.up(prefix: "my-prefix", repo: TestRepo)
      end
    end
  end
end
