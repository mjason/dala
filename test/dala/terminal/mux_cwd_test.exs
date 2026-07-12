defmodule Dala.Terminal.MuxCwdTest do
  # Shadows `zellij`/`tmux` with fake executables via PATH (process-global) — never async.
  use ExUnit.Case, async: false

  alias Dala.Terminal.MuxCwd

  setup do
    dir = Path.join(System.tmp_dir!(), "mux-cwd-#{System.unique_integer([:positive])}")
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

  defp fake_zellij_layout(dir, layout) do
    layout_file = Path.join(dir, "layout.kdl")
    File.write!(layout_file, layout)
    fake_bin(dir, "zellij", ~s(cat "#{layout_file}"\n))
  end

  describe "cwd/1 for zellij (dump-layout KDL parsing)" do
    test "focused pane without inline cwd falls back to the session base", %{dir: dir} do
      fake_zellij_layout(dir, """
      layout {
          cwd "/home/mj/dev"
          tab name="Tab #1" focus=true hide_floating_panes=true {
              pane size=1 borderless=true {
                  plugin location="zellij:tab-bar"
              }
              pane focus=true
              pane size=2 borderless=true {
                  plugin location="zellij:status-bar"
              }
          }
      }
      """)

      assert MuxCwd.cwd({:zellij, "s"}) == {:ok, "/home/mj/dev"}
    end

    test "focused pane with a relative cwd joins onto the session base", %{dir: dir} do
      fake_zellij_layout(dir, """
      layout {
          cwd "/home/mj/dev"
          tab name="Tab #1" focus=true {
              pane focus=true cwd="project"
              pane cwd="elsewhere"
          }
      }
      """)

      assert MuxCwd.cwd({:zellij, "s"}) == {:ok, "/home/mj/dev/project"}
    end

    test "focused pane with an absolute cwd wins over the base", %{dir: dir} do
      fake_zellij_layout(dir, """
      layout {
          cwd "/home/mj/dev"
          tab focus=true {
              pane focus=true cwd="/var/log"
          }
      }
      """)

      assert MuxCwd.cwd({:zellij, "s"}) == {:ok, "/var/log"}
    end

    test "relative pane cwd without a session base is rooted at /", %{dir: dir} do
      fake_zellij_layout(dir, """
      layout {
          tab focus=true {
              pane focus=true cwd="home/mj"
          }
      }
      """)

      assert MuxCwd.cwd({:zellij, "s"}) == {:ok, "/home/mj"}
    end

    test "no base and no focused-pane cwd is an error", %{dir: dir} do
      fake_zellij_layout(dir, """
      layout {
          tab focus=true {
              pane focus=true
          }
      }
      """)

      assert MuxCwd.cwd({:zellij, "s"}) == :error
    end

    test "the innermost focused pane wins in a nested pane tree", %{dir: dir} do
      fake_zellij_layout(dir, """
      layout {
          cwd "/base"
          tab focus=true {
              pane focus=true split_direction="vertical" cwd="outer" {
                  pane cwd="sibling"
                  pane focus=true cwd="inner"
              }
          }
      }
      """)

      assert MuxCwd.cwd({:zellij, "s"}) == {:ok, "/base/inner"}
    end

    test "panes in an unfocused tab are ignored", %{dir: dir} do
      fake_zellij_layout(dir, """
      layout {
          cwd "/base"
          tab name="other" {
              pane focus=true cwd="wrong"
          }
          tab name="current" focus=true {
              pane focus=true cwd="right"
          }
      }
      """)

      assert MuxCwd.cwd({:zellij, "s"}) == {:ok, "/base/right"}
    end

    test "a failing zellij binary yields :error", %{dir: dir} do
      fake_bin(dir, "zellij", "exit 1\n")

      assert MuxCwd.cwd({:zellij, "s"}) == :error
    end
  end

  describe "focused_command/1 for zellij" do
    test "reads the command of the innermost focused pane", %{dir: dir} do
      fake_zellij_layout(dir, """
      layout {
          cwd "/base"
          tab focus=true {
              pane focus=true {
                  pane command="nvim"
                  pane focus=true command="claude" cwd="project"
              }
          }
      }
      """)

      assert MuxCwd.focused_command({:zellij, "s"}) == {:ok, "claude"}
    end

    test "no command on any focused pane is an error", %{dir: dir} do
      fake_zellij_layout(dir, """
      layout {
          cwd "/base"
          tab focus=true {
              pane focus=true cwd="project"
          }
      }
      """)

      assert MuxCwd.focused_command({:zellij, "s"}) == :error
    end
  end

  describe "cwd/1 and focused_command/1 for tmux" do
    test "returns the trimmed pane_current_path", %{dir: dir} do
      fake_bin(dir, "tmux", "printf '/work/project\\n'\n")

      assert MuxCwd.cwd({:tmux, 999_999_999}) == {:ok, "/work/project"}
    end

    test "empty tmux output is an error", %{dir: dir} do
      fake_bin(dir, "tmux", "printf ''\n")

      assert MuxCwd.cwd({:tmux, 999_999_999}) == :error
    end

    test "a failing tmux binary is an error", %{dir: dir} do
      fake_bin(dir, "tmux", "exit 1\n")

      assert MuxCwd.cwd({:tmux, 999_999_999}) == :error
    end

    test "focused_command returns the trimmed pane_current_command", %{dir: dir} do
      fake_bin(dir, "tmux", "printf 'claude\\n'\n")

      assert MuxCwd.focused_command({:tmux, 999_999_999}) == {:ok, "claude"}
    end
  end

  describe "unknown mux values" do
    test "cwd/1 and focused_command/1 reject anything else" do
      assert MuxCwd.cwd(nil) == :error
      assert MuxCwd.cwd({:screen, "s"}) == :error
      assert MuxCwd.focused_command(nil) == :error
    end
  end
end
