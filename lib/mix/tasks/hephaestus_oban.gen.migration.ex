defmodule Mix.Tasks.HephaestusOban.Gen.Migration do
  @shortdoc "Generates HephaestusOban migration"
  @moduledoc """
  Generates the migration for HephaestusOban step_results table.

      $ mix hephaestus_oban.gen.migration
  """

  use Mix.Task

  import Mix.Ecto
  import Mix.Generator

  @impl true
  def run(args) do
    no_umbrella!("hephaestus_oban.gen.migration")
    repos = parse_repo(args)

    Enum.each(repos, fn repo ->
      ensure_repo(repo, args)
      path = Ecto.Migrator.migrations_path(repo)
      file = Path.join(path, "#{timestamp()}_create_hephaestus_step_results.exs")

      create_file(file, migration_template(repo))
    end)
  end

  defp timestamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.universal_time()
    "#{year}#{pad(month)}#{pad(day)}#{pad(hour)}#{pad(minute)}#{pad(second)}"
  end

  defp pad(integer) when integer < 10, do: "0#{integer}"
  defp pad(integer), do: "#{integer}"

  defp migration_template(repo) do
    """
    defmodule #{inspect(repo)}.Migrations.CreateHephaestusStepResults do
      use Ecto.Migration

      def up, do: HephaestusOban.Migration.up()
      def down, do: HephaestusOban.Migration.down()
    end
    """
  end
end
