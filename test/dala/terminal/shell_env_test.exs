defmodule Dala.Terminal.ShellEnvTest do
  # remove_list/1 takes an explicit env map — pure, so async is fine.
  use ExUnit.Case, async: true

  alias Dala.Terminal.ShellEnv

  # Everything a fresh local login would have survives.
  @survives ~w(
    HOME USER LOGNAME SHELL PATH TMPDIR TZ
    LANG LANGUAGE LC_ALL LC_CTYPE LC_MESSAGES
    XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_DATA_DIRS
    SSH_AUTH_SOCK SSH_AGENT_PID DBUS_SESSION_BUS_ADDRESS
    DISPLAY WAYLAND_DISPLAY XAUTHORITY
    WSL_DISTRO_NAME WSL_INTEROP WSLENV
    TERM COLORTERM WARP_CLI_AGENT_PROTOCOL_VERSION
  )

  # Server-process ancestry never reaches a shell — whatever it is.
  @removed ~w(
    CLAUDECODE CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION
    CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SSE_PORT CLAUDE_EFFORT
    CODEX_SANDBOX OPENCODE_SESSION
    DALA_AUTH_ENABLED DALA_USERS PHX_SERVER RELEASE_COOKIE
    PORT SECRET_KEY_BASE TOKEN_SIGNING_SECRET MIX_ENV
    TERM_PROGRAM TMUX ZELLIJ KITTY_WINDOW_ID VSCODE_INJECTION
    INVOCATION_ID JOURNAL_STREAM SYSTEMD_EXEC_PID
    ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR CODEX_HOME NODE_OPTIONS
  )

  test "allowlist: a fresh-login environment passes through untouched" do
    env = Map.new(@survives, &{&1, "x"})
    assert ShellEnv.remove_list(env) == []
  end

  test "everything outside the allowlist is removed — agent markers, server
        config/secrets, host-terminal identity, systemd plumbing, and even
        ad-hoc user exports (their rc re-creates what they configured)" do
    env = Map.new(@survives ++ @removed, &{&1, "x"})
    removed = ShellEnv.remove_list(env)

    for name <- @removed, do: assert(name in removed, "#{name} must be removed")
    for name <- @survives, do: refute(name in removed, "#{name} must survive")
  end

  test "REGRESSION: an agent-run deploy cannot make dala shells look like
        nested agent sessions" do
    # The exact leak a user hit: agent restarts the server inside a Claude
    # Code session → CLAUDE_CODE_CHILD_SESSION reaches the shell → claude
    # inside dala stops persisting history.
    env = %{"CLAUDE_CODE_CHILD_SESSION" => "1", "CLAUDECODE" => "1", "HOME" => "/home/u"}
    removed = ShellEnv.remove_list(env)
    assert "CLAUDE_CODE_CHILD_SESSION" in removed
    assert "CLAUDECODE" in removed
    refute "HOME" in removed
  end

  test "LC_TERMINAL identity smuggling is denied even inside the LC_ family" do
    removed = ShellEnv.remove_list(%{"LC_TERMINAL" => "iTerm2", "LC_CTYPE" => "UTF-8"})
    assert "LC_TERMINAL" in removed
    refute "LC_CTYPE" in removed
  end

  test "dala's own spawn additions are never in the removal list (the holder
        applies env before env_remove — removal would strip them)" do
    env = %{
      "TERM" => "xterm-256color",
      "COLORTERM" => "truecolor",
      "WARP_CLIENT_VERSION" => "dala"
    }

    assert ShellEnv.remove_list(env) == []
  end

  test "removal list only names variables that are actually present" do
    assert ShellEnv.remove_list(%{}) == []
  end
end
