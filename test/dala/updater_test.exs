defmodule Dala.UpdaterTest do
  # System env and Application env are process-global — never async.
  use ExUnit.Case, async: false

  alias Dala.Updater

  defp put_system_env(key, value) do
    old = System.get_env(key)
    System.put_env(key, value)

    on_exit(fn ->
      if old, do: System.put_env(key, old), else: System.delete_env(key)
    end)
  end

  defp put_release_root(value) do
    old = Application.get_env(:dala, :release_root)

    case value do
      nil -> Application.delete_env(:dala, :release_root)
      v -> Application.put_env(:dala, :release_root, v)
    end

    on_exit(fn ->
      case old do
        nil -> Application.delete_env(:dala, :release_root)
        v -> Application.put_env(:dala, :release_root, v)
      end
    end)
  end

  describe "repo/0" do
    test "defaults to the upstream repo when DALA_UPDATE_REPO is unset" do
      old = System.get_env("DALA_UPDATE_REPO")
      System.delete_env("DALA_UPDATE_REPO")
      on_exit(fn -> if old, do: System.put_env("DALA_UPDATE_REPO", old) end)

      assert Updater.repo() == "mjason/dala"
    end

    test "honours the update_repo app config (runtime.exs: updateRepo / legacy env)" do
      Application.put_env(:dala, :update_repo, "someone/fork")
      on_exit(fn -> Application.delete_env(:dala, :update_repo) end)
      assert Updater.repo() == "someone/fork"
    end
  end

  describe "release_root/0 and enabled?/0" do
    test "nil (disabled) when the app env is unset" do
      put_release_root(nil)

      assert Updater.release_root() == nil
      refute Updater.enabled?()
    end

    test "nil (disabled) when the app env is an empty string" do
      put_release_root("")

      assert Updater.release_root() == nil
      refute Updater.enabled?()
    end

    test "nil (disabled) when the app env is not a binary" do
      put_release_root(:not_a_path)

      assert Updater.release_root() == nil
      refute Updater.enabled?()
    end

    test "returns the configured root and enables the updater" do
      put_release_root("/opt/dala")

      assert Updater.release_root() == "/opt/dala"
      assert Updater.enabled?()
    end
  end

  describe "current_version/0" do
    test "is the running application's version and parses as semver" do
      version = Updater.current_version()

      assert version == to_string(Application.spec(:dala, :vsn))
      assert {:ok, _} = Version.parse(version)
    end
  end
end
