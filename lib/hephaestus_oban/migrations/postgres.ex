defmodule HephaestusOban.Migrations.Postgres do
  @moduledoc """
  PostgreSQL migration orchestrator for `HephaestusOban.Migration`.

  This module applies versioned migration steps (`V01`, `V02`, `V03`, ...)
  and records the latest applied version in the `hephaestus_step_results`
  table comment, following the same version-tracking pattern used by Oban.

  `up/1` applies only the missing versions up to the requested target.
  `down/1` rolls back from the current version down to the requested target.
  """

  use Ecto.Migration

  @initial_version 1
  @current_version 3
  @default_prefix "public"

  @valid_prefix ~r/^[a-z_][a-z0-9_]*$/

  def initial_version, do: @initial_version

  def current_version, do: @current_version

  def up(opts) do
    opts = with_defaults(opts, @current_version)
    initial = migrated_version(opts)

    cond do
      initial == 0 ->
        change(@initial_version..opts.version, :up, opts)

      initial < opts.version ->
        change((initial + 1)..opts.version, :up, opts)

      true ->
        :ok
    end
  end

  def down(opts) do
    opts = with_defaults(opts, @initial_version)
    initial = max(migrated_version(opts), @initial_version)

    cond do
      initial >= opts.version ->
        change(initial..(opts.version + 1)//-1, :down, opts)

      true ->
        :ok
    end
  end

  def migrated_version(opts) do
    opts = with_defaults(opts, @initial_version)

    repo = Map.get_lazy(opts, :repo, fn -> repo() end)
    table = qualified_table(opts.prefix, "hephaestus_step_results")

    query = """
    SELECT pg_catalog.obj_description('#{table}'::regclass, 'pg_class')
    """

    case repo.query(query, [], log: false) do
      {:ok, %{rows: [[version]]}} when is_binary(version) -> String.to_integer(version)
      _ -> 0
    end
  end

  defp change(range, direction, opts) do
    for index <- range do
      pad_idx = String.pad_leading(to_string(index), 2, "0")

      [__MODULE__, "V#{pad_idx}"]
      |> Module.concat()
      |> apply(direction, [opts])
    end

    case direction do
      :up -> record_version(opts, Enum.max(range))
      :down -> record_version(opts, Enum.min(range) - 1)
    end
  end

  defp record_version(_opts, 0), do: :ok

  defp record_version(%{prefix: prefix}, version) do
    execute(
      "COMMENT ON TABLE #{qualified_table(prefix, "hephaestus_step_results")} IS '#{version}'"
    )
  end

  defp with_defaults(opts, version) do
    opts = Enum.into(opts, %{prefix: @default_prefix, version: version})

    validate_prefix!(opts.prefix)

    opts
    |> Map.put(:escaped_prefix, String.replace(opts.prefix, "'", "\\'"))
  end

  defp validate_prefix!(prefix) do
    unless Regex.match?(@valid_prefix, prefix) do
      raise ArgumentError,
            "invalid prefix #{inspect(prefix)} — must match #{inspect(@valid_prefix)}"
    end
  end

  defp qualified_table("public", table), do: table
  defp qualified_table(prefix, table), do: "#{prefix}.#{table}"
end
