defmodule HephaestusOban.Migrations.Postgres.V04 do
  @moduledoc false

  use Ecto.Migration

  def up(%{prefix: prefix}) do
    quoted = inspect(prefix)

    # Change instance_id from uuid to varchar(255) to match
    # hephaestus_ecto v03 which changed workflow_instances.id
    # from uuid to varchar(255) for business key IDs ("key::value").
    #
    # Must drop FK first, alter type, then recreate FK.
    # Uses IF checks to be idempotent — safe to re-run if version comment is lost.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = '#{prefix}'
        AND table_name = 'hephaestus_step_results'
        AND column_name = 'instance_id'
        AND data_type = 'uuid'
      ) THEN
        ALTER TABLE #{quoted}.hephaestus_step_results
          DROP CONSTRAINT IF EXISTS hephaestus_step_results_instance_id_fkey;

        ALTER TABLE #{quoted}.hephaestus_step_results
          ALTER COLUMN instance_id TYPE varchar(255) USING instance_id::text;

        ALTER TABLE #{quoted}.hephaestus_step_results
          ADD CONSTRAINT hephaestus_step_results_instance_id_fkey
          FOREIGN KEY (instance_id)
          REFERENCES #{quoted}.workflow_instances(id)
          ON DELETE CASCADE;
      END IF;
    END
    $$;
    """)
  end

  def down(%{prefix: _prefix}) do
    # Intentionally a no-op: the uuid -> varchar(255) type change is irreversible
    # once instances have been written with "key::value" IDs. Rolling back via
    # down/1 only resets the version comment; the column stays varchar(255).
    :ok
  end
end
