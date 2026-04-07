{:ok, _} = HephaestusOban.TestRepo.start_link()
{:ok, _} = Oban.start_link(Application.fetch_env!(:hephaestus_oban, Oban))
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(HephaestusOban.TestRepo, :manual)
