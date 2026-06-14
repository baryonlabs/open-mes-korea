defmodule OpenMes.Repo do
  use Ecto.Repo,
    otp_app: :open_mes,
    adapter: Ecto.Adapters.Postgres
end
