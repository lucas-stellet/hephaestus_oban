import Config

config :hephaestus_oban, HephaestusOban.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "hephaestus_oban_test",
  pool: Ecto.Adapters.SQL.Sandbox

config :hephaestus_oban, Oban,
  repo: HephaestusOban.TestRepo,
  queues: false,
  testing: :manual
