defmodule Dala.Terminal.ShellEnvTest do
  # remove_list/1 takes an explicit env map — pure, so async is fine.
  use ExUnit.Case, async: true

  alias Dala.Terminal.ShellEnv

  describe "agent session markers" do
    test "REGRESSION: a dala server (re)started from inside a Claude Code session
          must not make its shells look like nested agent sessions" do
      # The exact leak a user hit: agent-run deploy → server inherits the
      # session plumbing → `claude` in a dala terminal sees CHILD_SESSION
      # and stops persisting history.
      env = %{
        "CLAUDECODE" => "1",
        "CLAUDE_CODE_ENTRYPOINT" => "cli",
        "CLAUDE_CODE_SESSION_ID" => "abc",
        "CLAUDE_CODE_CHILD_SESSION" => "1",
        "CLAUDE_CODE_BRIDGE_SESSION_ID" => "abc",
        "CLAUDE_CODE_SSE_PORT" => "12345",
        "CLAUDE_EFFORT" => "high",
        "PATH" => "/usr/bin"
      }

      names = ShellEnv.remove_list(env)

      for marker <- Map.keys(env), marker != "PATH" do
        assert marker in names, "expected #{marker} to be scrubbed"
      end
    end

    test "codex sandbox markers are scrubbed" do
      names = ShellEnv.remove_list(%{"CODEX_SANDBOX" => "seatbelt"})
      assert "CODEX_SANDBOX" in names
      assert "CODEX_SANDBOX_NETWORK_DISABLED" in names
    end

    test "deliberate user agent CONFIG is left alone" do
      env = %{
        "CLAUDE_CONFIG_DIR" => "/home/u/.claude-alt",
        "ANTHROPIC_API_KEY" => "sk-x",
        "CODEX_HOME" => "/home/u/.codex",
        "OPENCODE_CONFIG" => "/home/u/.config/opencode.json"
      }

      names = ShellEnv.remove_list(env)
      for name <- Map.keys(env), do: refute(name in names, "#{name} must survive")
    end
  end

  describe "families" do
    test "prefix families are matched against the given environment only" do
      names = ShellEnv.remove_list(%{"DALA_X" => "1", "CLAUDE_CODE_Y" => "1"})
      assert "DALA_X" in names
      assert "CLAUDE_CODE_Y" in names
      refute "DALA_OTHER" in names
    end

    test "host terminal + server config exacts are always present" do
      names = ShellEnv.remove_list(%{})

      for name <- ~w(TERM_PROGRAM TMUX ZELLIJ PORT SECRET_KEY_BASE MIX_ENV) do
        assert name in names
      end
    end

    test "ordinary user environment is untouched" do
      names =
        ShellEnv.remove_list(%{"PATH" => "x", "HOME" => "y", "LANG" => "z", "EDITOR" => "vim"})

      for name <- ~w(PATH HOME LANG EDITOR), do: refute(name in names)
    end
  end
end
