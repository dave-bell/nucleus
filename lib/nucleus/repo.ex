defmodule Nucleus.Repo do
  use Ecto.Repo,
    otp_app: :nucleus,
    adapter: Ecto.Adapters.Postgres
end
