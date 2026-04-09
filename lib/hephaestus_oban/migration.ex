defmodule HephaestusOban.Migration do
  @moduledoc """
  Migrations create and modify the database tables HephaestusOban needs to function.

  ## Usage

  To use migrations in your application you'll need to generate an `Ecto.Migration` that wraps
  calls to `HephaestusOban.Migration`:

      defmodule MyApp.Repo.Migrations.AddHephaestusOban do
        use Ecto.Migration

        def up, do: HephaestusOban.Migration.up()
        def down, do: HephaestusOban.Migration.down()
      end

  ## Isolation with Prefixes

  HephaestusOban supports namespacing through PostgreSQL schemas (prefixes):

      def up, do: HephaestusOban.Migration.up(prefix: "private")
      def down, do: HephaestusOban.Migration.down(prefix: "private")

  ## Versioning

  Migrations are versioned and tracked via PostgreSQL table comments. Running `up/1`
  will only apply migrations that haven't been run yet.

  New installs can run all known versions:

      def up, do: HephaestusOban.Migration.up()
      def down, do: HephaestusOban.Migration.down()

  Existing installs can upgrade incrementally to a specific version:

      def up, do: HephaestusOban.Migration.up(version: 3)
      def down, do: HephaestusOban.Migration.down(version: 2)

  Use `migrated_version/1` to inspect the recorded version:

      HephaestusOban.Migration.migrated_version()
      HephaestusOban.Migration.migrated_version(prefix: "private")
  """

  use Ecto.Migration

  @doc """
  Run the `up` changes for all migrations between the initial version and the current version.

  ## Options

    * `:version` — target version (defaults to latest)
    * `:prefix` — PostgreSQL schema prefix (defaults to `"public"`)

  Versions are cumulative. For example, `up(version: 3)` runs V01, V02, and V03
  on a fresh install, or only the missing migrations on an existing install.
  """
  def up(opts \\ []) when is_list(opts) do
    HephaestusOban.Migrations.Postgres.up(opts)
  end

  @doc """
  Run the `down` changes from the current version to the target version.

  ## Options

    * `:version` — target version to migrate down to (defaults to initial)
    * `:prefix` — PostgreSQL schema prefix (defaults to `"public"`)

  For example, `down(version: 2)` removes V03 changes while keeping V01 and V02 applied.
  """
  def down(opts \\ []) when is_list(opts) do
    HephaestusOban.Migrations.Postgres.down(opts)
  end

  @doc """
  Check the latest version the database is migrated to.

  ## Options

    * `:prefix` — PostgreSQL schema prefix (defaults to `"public"`)
  """
  def migrated_version(opts \\ []) when is_list(opts) do
    HephaestusOban.Migrations.Postgres.migrated_version(opts)
  end
end
