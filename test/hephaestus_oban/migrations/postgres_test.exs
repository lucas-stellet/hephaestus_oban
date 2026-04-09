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

      assert 0 = Postgres.migrated_version(opts)
    end

    test "returns an integer for a migrated database", %{opts: opts} do
      assert version = Postgres.migrated_version(opts)
      assert is_integer(version)
    end
  end

  describe "up/1 idempotency" do
    test "calling up/1 twice is a no-op", %{opts: opts} do
      assert :ok = Postgres.up(opts)
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
