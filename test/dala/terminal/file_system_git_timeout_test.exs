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
    path_separator = if Dala.Platform.windows?(), do: ";", else: ":"
    System.put_env("PATH", bin <> path_separator <> old_path)
    Application.put_env(:dala, :list_files_git_timeout_ms, 100)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      Application.delete_env(:dala, :list_files_git_timeout_ms)
      File.rm_rf!(base)
    end)

    %{bin: bin, root: root}
  end

  defp fake_git(bin, script) do
    if Dala.Platform.windows?() do
      path = Path.join(bin, "git.cmd")
      File.write!(path, "@echo off\r\n" <> String.replace(script, "\n", "\r\n"))
    else
      path = Path.join(bin, "git")
      File.write!(path, "#!/bin/sh\n" <> script)
      File.chmod!(path, 0o755)
    end
  end

  defp list_files(path) do
    Dala.Terminal.FileSystem
    |> Ash.ActionInput.for_action(:list_files, %{path: path})
    |> Ash.run_action()
  end

  test "a hung git is killed and the manual walk takes over", %{bin: bin, root: root} do
    File.write!(Path.join(root, "seen.txt"), "x")

    script =
      if Dala.Platform.windows?(),
        do: "%SystemRoot%\\System32\\ping.exe 127.0.0.1 -n 6 >NUL\n",
        else: "sleep 5\n"

    fake_git(bin, script)

    assert {:ok, %{files: files, truncated: false}} = list_files(root)
    assert files == ["seen.txt"]
  end

  test "a crashing git falls back to the manual walk", %{bin: bin, root: root} do
    File.write!(Path.join(root, "seen.txt"), "x")

    fake_git(bin, if(Dala.Platform.windows?(), do: "exit /B 128\n", else: "exit 128\n"))

    assert {:ok, %{files: files, truncated: false}} = list_files(root)
    assert files == ["seen.txt"]
  end
end
