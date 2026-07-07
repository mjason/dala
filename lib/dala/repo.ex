defmodule Dala.Repo do
  use AshSqlite.Repo,
    otp_app: :dala
end
