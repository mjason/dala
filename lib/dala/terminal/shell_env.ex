defmodule Dala.Terminal.ShellEnv do
  @moduledoc """
  Environment hygiene for the shells dala spawns.

  A dala shell must look like a FRESH terminal, not like a child of whatever
  process happened to start the dala server. Everything here exists because
  a leak of that ancestry broke something real for a user:

  1. **Host-terminal identity** — TERM_PROGRAM/kitty/ghostty/tmux/… make
     shell integrations and TUIs negotiate protocols the web terminal does
     not speak.
  2. **Dala's own server configuration** — a dev `mix phx.server` run inside
     a dala terminal grabbing the production PORT/PHX_SERVER, a test server
     coming up with the production DALA_AUTH_ENABLED. Secrets included.
  3. **Agent session markers** — when the dala server itself was (re)started
     from inside an agent session (an agent running the deploy is normal
     practice here), the agent's session plumbing leaks down. A `claude`
     started inside a dala terminal then sees CLAUDE_CODE_CHILD_SESSION /
     CLAUDECODE and behaves as a NESTED session — which, among other things,
     does not persist its history.

  Deliberate user configuration is NOT scrubbed (CLAUDE_CONFIG_DIR,
  CODEX_HOME, ANTHROPIC_API_KEY, …): the spawned shell runs the user's rc
  files, which re-export anything they configured on purpose. The
  `CLAUDE_CODE_*` prefix is knowingly broad — it also covers ad-hoc config
  like CLAUDE_CODE_USE_BEDROCK exported only in the launching terminal, and
  losing an ad-hoc override beats inheriting a phantom parent session.
  """

  # -- 1. host-terminal identity ---------------------------------------------
  @host_terminal ~w(
    TERM_PROGRAM TERM_PROGRAM_VERSION
    GHOSTTY_RESOURCES_DIR GHOSTTY_BIN_DIR GHOSTTY_SHELL_INTEGRATION_NO_SUDO
    KITTY_WINDOW_ID KITTY_PID KITTY_INSTALLATION_DIR KITTY_PUBLIC_KEY
    WEZTERM_EXECUTABLE WEZTERM_CONFIG_FILE WEZTERM_PANE WEZTERM_UNIX_SOCKET
    ITERM_SESSION_ID LC_TERMINAL LC_TERMINAL_VERSION
    VTE_VERSION WT_SESSION WT_PROFILE_ID
    TMUX TMUX_PANE STY ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID
    VSCODE_INJECTION VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_IPC_HANDLE
  )

  # -- 2. dala's own server configuration ------------------------------------
  @server_config ~w(
    PORT DATABASE_PATH POOL_SIZE SECRET_KEY_BASE TOKEN_SIGNING_SECRET
    DNS_CLUSTER_QUERY MIX_ENV ELIXIR_ERL_OPTIONS ROOTDIR BINDIR EMU PROGNAME
  )

  # -- 3. agent session markers ----------------------------------------------
  # Exact names observed from real agent CLIs marking "you are inside my
  # session". Add here when a new agent's nesting marker surfaces.
  @agent_markers ~w(
    CLAUDECODE CLAUDE_EFFORT
    CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED
  )

  # Open-ended families, matched against the live environment at spawn time
  # so plumbing added later can never leak by omission.
  @prefixes ~w(DALA_ PHX_ RELEASE_ CLAUDE_CODE_)

  @doc "The full removal list against the CURRENT process environment."
  def remove_list, do: remove_list(System.get_env())

  @doc """
  The full removal list against an explicit environment map (pure — this is
  the tested core; `remove_list/0` is the production entry).
  """
  def remove_list(env) when is_map(env) do
    inherited =
      for {name, _value} <- env,
          String.starts_with?(name, @prefixes),
          do: name

    @host_terminal ++ @server_config ++ @agent_markers ++ inherited
  end
end
