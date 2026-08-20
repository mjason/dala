defmodule Dala.UpdaterTest do
  # System env and Application env are process-global — never async.
  use ExUnit.Case, async: false

  alias Dala.Updater
  alias Dala.Updater.Status

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

  describe "queue_windows_activation/1" do
    @tag :tmp_dir
    test "fails before creating a request when the independent queue script is missing", %{
      tmp_dir: tmp_dir
    } do
      put_release_root(tmp_dir)
      File.write!(Path.join(tmp_dir, "update-helper.ps1"), "")

      assert {:error, message} = Updater.queue_windows_activation("v1.2.3")
      assert message =~ "Windows update queue is missing"
      assert Status.read(tmp_dir).state == "failed"
      assert Path.wildcard(Path.join(tmp_dir, ".update-request-*.json")) == []
    end

    @tag :tmp_dir
    test "returns pending after the helper task is queued", %{tmp_dir: tmp_dir} do
      if match?({:win32, :nt}, :os.type()) do
        put_release_root(tmp_dir)
        File.write!(Path.join(tmp_dir, "update-helper.ps1"), "")

        queue = Path.join(tmp_dir, "queue-update.ps1")

        File.write!(
          queue,
          "param([string]$HelperPath, [string]$RequestPath, [string]$TaskName)\nexit 0\n"
        )

        assert {:ok, %{state: "pending", target: "v1.2.3"}} =
                 Updater.queue_windows_activation("v1.2.3")

        assert Status.read(tmp_dir).state == "queued"
      else
        :ok
      end
    end
  end
end
