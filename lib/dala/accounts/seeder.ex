defmodule Dala.Accounts.Seeder do
  @moduledoc """
  Seeds pre-configured accounts at boot from the `DALA_USERS` environment
  variable (`email:password` pairs separated by commas or newlines).
  Existing accounts get their password updated, so `DALA_USERS` is the
  source of truth for credentials.

  When authentication is enabled the system refuses to boot without at least
  one account — otherwise nobody could ever sign in.
  """

  require Logger

  def child_spec(_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :transient}
  end

  @doc "Runs synchronously during supervision-tree startup."
  def start_link do
    run()
    :ignore
  end

  def run do
    System.get_env("DALA_USERS", "")
    |> String.split([",", ";", "\n"], trim: true)
    |> Enum.each(&seed_user/1)

    verify_accounts_exist!()
  end

  defp seed_user(pair) do
    case String.split(String.trim(pair), ":", parts: 2) do
      [email, password] when email != "" and byte_size(password) >= 8 ->
        Dala.Accounts.User
        |> Ash.Changeset.for_create(:seed_user, %{email: email, password: password},
          authorize?: false
        )
        |> Ash.create!()

        Logger.info("seeded account #{email}")

      _ ->
        Logger.warning(
          "ignored invalid DALA_USERS entry (expected email:password with password of at least 8 characters)"
        )
    end
  end

  defp verify_accounts_exist! do
    if Dala.Auth.enabled?() and Ash.count!(Dala.Accounts.User, authorize?: false) == 0 do
      raise """
      DALA_AUTH_ENABLED is set but no accounts exist.
      Configure at least one account, e.g.:

          DALA_USERS="admin@example.com:changeme123"
      """
    end
  end
end
