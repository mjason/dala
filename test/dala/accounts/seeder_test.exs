defmodule Dala.Accounts.SeederTest do
  # Manipulates process-global env vars.
  use Dala.DataCase, async: false

  alias Dala.Accounts.Seeder

  # The seeder reads Application env (:bootstrap_users/_reset — set by
  # runtime.exs from config.jsonc, or from the legacy DALA_USERS env vars).
  @app_keys %{"DALA_USERS" => :bootstrap_users, "DALA_USERS_RESET" => :bootstrap_users_reset}

  defp put_bootstrap(name, value) do
    key = Map.fetch!(@app_keys, name)

    case {key, value} do
      {_, nil} -> Application.delete_env(:dala, key)
      {:bootstrap_users_reset, v} -> Application.put_env(:dala, key, v in ["true", "1", true])
      {_, v} -> Application.put_env(:dala, key, v)
    end
  end

  defp with_env(pairs, fun) do
    originals =
      Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:dala, Map.fetch!(@app_keys, k))} end)

    Enum.each(pairs, fn {k, v} -> put_bootstrap(k, v) end)

    on_exit(fn ->
      Enum.each(originals, fn
        {k, nil} -> Application.delete_env(:dala, Map.fetch!(@app_keys, k))
        {k, v} -> Application.put_env(:dala, Map.fetch!(@app_keys, k), v)
      end)
    end)

    fun.()
  end

  defp hashed_password!(email) do
    require Ash.Query

    Dala.Accounts.User
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one!(authorize?: false)
    |> Map.get(:hashed_password)
  end

  defp unique_email, do: "seed-#{System.unique_integer([:positive])}@example.com"

  test "creates the account on first boot" do
    email = unique_email()

    with_env([{"DALA_USERS", "#{email}:bootstrap-pass"}, {"DALA_USERS_RESET", nil}], fn ->
      Seeder.run()
      assert hashed_password!(email)
    end)
  end

  test "an existing account is NEVER reset by a lingering DALA_USERS line" do
    email = unique_email()

    with_env([{"DALA_USERS", "#{email}:original-pass"}, {"DALA_USERS_RESET", nil}], fn ->
      Seeder.run()
      original_hash = hashed_password!(email)

      # Same email, different password still in the env file — a stale
      # plaintext line must not become the account's password.
      put_bootstrap("DALA_USERS", "#{email}:attacker-edited")
      Seeder.run()

      assert hashed_password!(email) == original_hash
    end)
  end

  test "DALA_USERS_RESET=true restores the explicit recovery reset" do
    email = unique_email()

    with_env([{"DALA_USERS", "#{email}:original-pass"}, {"DALA_USERS_RESET", nil}], fn ->
      Seeder.run()
      original_hash = hashed_password!(email)

      put_bootstrap("DALA_USERS", "#{email}:recovered-pass")
      put_bootstrap("DALA_USERS_RESET", "true")
      Seeder.run()

      refute hashed_password!(email) == original_hash
    end)
  end

  test "removing DALA_USERS after bootstrap keeps booting (accounts persist)" do
    email = unique_email()

    with_env([{"DALA_USERS", "#{email}:bootstrap-pass"}, {"DALA_USERS_RESET", nil}], fn ->
      Seeder.run()

      put_bootstrap("DALA_USERS", nil)
      # Must not raise: at least one account exists in the DB.
      Seeder.run()
      assert hashed_password!(email)
    end)
  end

  test "invalid entries are ignored with a warning, not a crash" do
    with_env([{"DALA_USERS", "no-colon-here,short@x.io:tiny"}, {"DALA_USERS_RESET", nil}], fn ->
      Seeder.run()
    end)
  end
end
