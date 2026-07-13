defmodule Dala.Terminal.FileSystemGitTimeoutTest do
  # Shadows `git` with a fake executable via PATH (process-global) and tunes
  # the git deadline via app env (also global) — never async.
  use ExUnit.Case, async: false

  setup do
    base = Path.join(System.tmp_dir!(), "dala-fs-git-#{System.unique_integer([:positive])}")
    bin = Path.join(base, "bin")
    root = Path.join(base, "repo")
    File.mkdir_p!(bin)
    File.mkdir_p!(root)

    old_path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> old_path)
    Application.put_env(:dala, :list_files_git_timeout_ms, 100)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      Application.delete_env(:dala, :list_files_git_timeout_ms)
      File.rm_rf!(base)
    end)

    %{bin: bin, root: root}
  end

  defp fake_git(bin, script) do
    path = Path.join(bin, "git")
    File.write!(path, "#!/bin/sh\n" <> script)
    File.chmod!(path, 0o755)
  end

  defp list_files(path) do
    Dala.Terminal.FileSystem
    |> Ash.ActionInput.for_action(:list_files, %{path: path})
    |> Ash.run_action()
  end

  test "a hung git is killed and the manual walk takes over", %{bin: bin, root: root} do
    File.write!(Path.join(root, "seen.txt"), "x")

    fake_git(bin, """
    case "$*" in
      *rev-parse*) echo "#{root}"; exit 0;;
      *) sleep 5;;
    esac
    """)

    assert {:ok, %{files: files, truncated: false}} = list_files(root)
    assert files == ["seen.txt"]
  end

  test "a crashing git falls back to the manual walk", %{bin: bin, root: root} do
    File.write!(Path.join(root, "seen.txt"), "x")

    fake_git(bin, """
    case "$*" in
      *rev-parse*) echo "#{root}"; exit 0;;
      *) exit 128;;
    esac
    """)

    assert {:ok, %{files: files, truncated: false}} = list_files(root)
    assert files == ["seen.txt"]
  end
end
