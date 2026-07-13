defmodule Dala.Accounts.SeederTest do
  # Manipulates process-global env vars.
  use Dala.DataCase, async: false

  alias Dala.Accounts.Seeder

  defp with_env(pairs, fun) do
    originals = Enum.map(pairs, fn {k, _} -> {k, System.get_env(k)} end)

    Enum.each(pairs, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)

    on_exit(fn ->
      Enum.each(originals, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
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
      System.put_env("DALA_USERS", "#{email}:attacker-edited")
      Seeder.run()

      assert hashed_password!(email) == original_hash
    end)
  end

  test "DALA_USERS_RESET=true restores the explicit recovery reset" do
    email = unique_email()

    with_env([{"DALA_USERS", "#{email}:original-pass"}, {"DALA_USERS_RESET", nil}], fn ->
      Seeder.run()
      original_hash = hashed_password!(email)

      System.put_env("DALA_USERS", "#{email}:recovered-pass")
      System.put_env("DALA_USERS_RESET", "true")
      Seeder.run()

      refute hashed_password!(email) == original_hash
    end)
  end

  test "removing DALA_USERS after bootstrap keeps booting (accounts persist)" do
    email = unique_email()

    with_env([{"DALA_USERS", "#{email}:bootstrap-pass"}, {"DALA_USERS_RESET", nil}], fn ->
      Seeder.run()

      System.delete_env("DALA_USERS")
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
