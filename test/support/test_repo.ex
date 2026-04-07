defmodule HephaestusOban.TestRepo do
  use Ecto.Repo,
    otp_app: :hephaestus_oban,
    adapter: Ecto.Adapters.Postgres
end
