defmodule Dala.Accounts.Seeder do
  @moduledoc """
  Bootstraps accounts at boot from the `DALA_USERS` environment variable
  (`email:password` pairs separated by commas or newlines).

  BOOTSTRAP-ONLY semantics: an entry only creates the account when that
  email does not exist yet. Existing accounts are never touched, so the
  plaintext line can (and should) be REMOVED from the env file after the
  first successful boot — leaving credentials in `dala.env` forever hands
  the password to anyone who can read the file.

  Forgot a password? Set `DALA_USERS_RESET=true` for ONE boot to restore
  the old reset-from-env behavior, then remove both variables again.

  When authentication is enabled the system refuses to boot without at
  least one account — otherwise nobody could ever sign in.
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
    reset? = Application.get_env(:dala, :bootstrap_users_reset, false)

    Application.get_env(:dala, :bootstrap_users, "")
    |> String.split([",", ";", "\n"], trim: true)
    |> Enum.each(&seed_user(&1, reset?))

    verify_accounts_exist!()
  end

  defp seed_user(pair, reset?) do
    case String.split(String.trim(pair), ":", parts: 2) do
      [email, password] when email != "" and byte_size(password) >= 8 ->
        cond do
          user_exists?(email) and not reset? ->
            Logger.info(
              "account #{email} already exists — DALA_USERS entry ignored. " <>
                "You can remove the plaintext line from your env file now " <>
                "(set DALA_USERS_RESET=true for one boot to force a password reset)."
            )

          true ->
            Dala.Accounts.User
            |> Ash.Changeset.for_create(:seed_user, %{email: email, password: password},
              authorize?: false
            )
            |> Ash.create!()

            action = if reset?, do: "reset password for", else: "created"

            Logger.info(
              "#{action} account #{email}. Remove the DALA_USERS line from your " <>
                "env file — the account is persisted and the plaintext is no " <>
                "longer needed."
            )
        end

      _ ->
        Logger.warning(
          "ignored invalid DALA_USERS entry (expected email:password with password of at least 8 characters)"
        )
    end
  end

  defp user_exists?(email) do
    require Ash.Query

    Dala.Accounts.User
    |> Ash.Query.filter(email == ^email)
    |> Ash.count!(authorize?: false) > 0
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
