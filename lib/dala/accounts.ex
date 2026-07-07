defmodule Dala.Accounts do
  use Ash.Domain, otp_app: :dala, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Dala.Accounts.Token
    resource Dala.Accounts.User
  end
end
