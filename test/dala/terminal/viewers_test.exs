defmodule Dala.Terminal.ViewersTest do
  # Shadows `ps`/`kill` with fake executables via PATH (process-global) — never async.
  use ExUnit.Case, async: false

  alias Dala.Terminal.Viewers

  setup do
    dir = Path.join(System.tmp_dir!(), "viewers-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old_path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defp fake_bin(dir, name, script) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> script)
    File.chmod!(path, 0o755)
    path
  end

  # Fake `ps -eo pid=,ppid=,args=` with a crafted process table.
  defp fake_ps(dir, table) do
    table_file = Path.join(dir, "ps-table.txt")
    File.write!(table_file, table)
    fake_bin(dir, "ps", ~s(cat "#{table_file}"\n))
  end

  describe "find_mux/1 zellij client arg parsing" do
    for {args, session} <- [
          {"zellij attach mysess", "mysess"},
          {"zellij a mysess", "mysess"},
          {"zellij -s mysess", "mysess"},
          {"zellij --session mysess", "mysess"},
          {"zellij attach --create mysess", "mysess"},
          {"/usr/bin/zellij attach mysess", "mysess"}
        ] do
      test "resolves the session from `#{args}`", %{dir: dir} do
        fake_ps(dir, """
          100     1 -zsh
          200   100 #{unquote(args)}
        """)

        assert Viewers.find_mux(100) == {:zellij, unquote(session)}
      end
    end

    test "the zellij server process is not a client", %{dir: dir} do
      fake_ps(dir, """
        100     1 -zsh
        200   100 zellij --server /run/user/1000/zellij
      """)

      assert Viewers.find_mux(100) == nil
    end

    test "plain `zellij` (random session name) resolves to no session", %{dir: dir} do
      fake_ps(dir, """
        100     1 -zsh
        200   100 zellij
      """)

      assert Viewers.find_mux(100) == nil
    end

    test "non-zellij binaries whose args mention sessions are ignored", %{dir: dir} do
      fake_ps(dir, """
        100     1 -zsh
        200   100 vim zellij-attach-notes.md
      """)

      assert Viewers.find_mux(100) == nil
    end
  end

  describe "find_mux/1 tmux and process-tree walking" do
    test "any tmux process inside the subtree is the client", %{dir: dir} do
      fake_ps(dir, """
        100     1 -zsh
        200   100 tmux attach -t work
      """)

      assert Viewers.find_mux(100) == {:tmux, 200}
    end

    test "finds a client that is a grandchild of the shell", %{dir: dir} do
      fake_ps(dir, """
        100     1 -zsh
        150   100 sh -c something
        200   150 zellij attach deep
      """)

      assert Viewers.find_mux(100) == {:zellij, "deep"}
    end

    test "clients outside the shell's subtree are invisible", %{dir: dir} do
      fake_ps(dir, """
        100     1 -zsh
        900     1 zellij attach other
        901     1 tmux attach
      """)

      assert Viewers.find_mux(100) == nil
    end

    test "invalid shell pids resolve to nil" do
      assert Viewers.find_mux(nil) == nil
      assert Viewers.find_mux(-1) == nil
      assert Viewers.find_mux("100") == nil
    end
  end

  describe "kick_others/1" do
    test "kills every other zellij client of the same session, and only those", %{dir: dir} do
      kill_log = Path.join(dir, "kill.log")
      fake_bin(dir, "kill", ~s(echo "$@" >> "#{kill_log}"\n))

      fake_ps(dir, """
        100     1 -zsh
        200   100 zellij attach s1
        900     1 zellij attach s1
        950     1 zellij attach other
      """)

      assert {:ok, %{multiplexer: "zellij", session: "s1", kicked: 1}} =
               Viewers.kick_others(100)

      assert File.read!(kill_log) |> String.trim() == "900"
    end

    test "no client under the shell is a descriptive error", %{dir: dir} do
      fake_ps(dir, """
        100     1 -zsh
        200   100 vim notes.md
      """)

      assert {:error, "no zellij/tmux client is running in this session"} =
               Viewers.kick_others(100)
    end

    test "invalid shell pids are rejected" do
      assert {:error, "shell is not running"} = Viewers.kick_others(nil)
      assert {:error, "shell is not running"} = Viewers.kick_others(0)
    end
  end

  describe "foreground_cmdline/1" do
    test "nonexistent pids and invalid input resolve to nil" do
      assert Viewers.foreground_cmdline(999_999_999) == nil
      assert Viewers.foreground_cmdline(nil) == nil
      assert Viewers.foreground_cmdline(-5) == nil
    end
  end
end
