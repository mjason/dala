defmodule Dala.Terminal.ShellEnv do
  @moduledoc """
  Environment hygiene for the shells dala spawns — **allowlist, not
  blocklist**.

  The server process's environment is an accident of however it was started:
  systemd, a dev terminal, or an agent session running the deploy (normal
  practice here). Passing that accident down created a whole class of bugs —
  production PORT/secrets visible in user shells, host-terminal protocol
  negotiation (kitty/ghostty), and most recently agent session markers
  (CLAUDE_CODE_CHILD_SESSION leaking made a `claude` inside a dala terminal
  behave as a nested session and stop persisting history). Chasing those
  with an ever-growing blocklist loses by construction.

  So dala shells start the way an SSH login does: a minimal, well-understood
  environment, and the user's own rc files rebuild the rest. Anything the
  user configured on purpose comes back via their profile; anything that was
  session plumbing of the server's ancestor never existed for the shell.

  The allowlist covers what a fresh local login would have:
  - identity & paths: HOME/USER/SHELL/PATH/TMPDIR/TZ
  - locale: LANG/LANGUAGE + `LC_*` (minus LC_TERMINAL* — iTerm smuggles
    terminal identity through the LC_ namespace because SSH forwards it)
  - XDG dirs (XDG_RUNTIME_DIR also hosts dala's own holder sockets)
  - session services a local shell relies on: ssh-agent, gpg, D-Bus
  - display access: a dala terminal on this machine is a local terminal
  - WSL interop plumbing
  - the variables dala itself injects at spawn (TERM/COLORTERM/WARP_*):
    the holder applies `env` before `env_remove`, so these must be allowed
    or dala would strip its own additions.
  """

  @allow_exact ~w(
    HOME USER LOGNAME SHELL PATH TMPDIR TZ
    LANG LANGUAGE
    SSH_AUTH_SOCK SSH_AGENT_PID GPG_AGENT_INFO DBUS_SESSION_BUS_ADDRESS
    DISPLAY WAYLAND_DISPLAY XAUTHORITY
    WSL_DISTRO_NAME WSL_INTEROP WSLENV PULSE_SERVER
    TERM COLORTERM
  )

  @allow_prefixes ~w(LC_ XDG_ WARP_)

  # Denied even inside an allowed family: terminal identity smuggled through
  # the SSH-forwarded LC_ namespace breaks TUIs exactly like TERM_PROGRAM.
  @deny_exact ~w(LC_TERMINAL LC_TERMINAL_VERSION)

  @doc "Removal list against the CURRENT process environment."
  def remove_list, do: remove_list(System.get_env())

  @doc """
  Every variable name in `env` that must NOT reach a spawned shell — i.e.
  everything outside the allowlist. Pure core; `remove_list/0` is the
  production entry.
  """
  def remove_list(env) when is_map(env) do
    for {name, _value} <- env, not allowed?(name), do: name
  end

  @doc false
  def allowed?(name) do
    name not in @deny_exact and
      (name in @allow_exact or String.starts_with?(name, @allow_prefixes))
  end
end
