defmodule Dala.Terminal.Foreground do
  @moduledoc """
  Which program currently owns a session's tty.

  Used to tell a plain shell prompt from a running CLI agent (claude, codex,
  opencode, …) so agent-specific delivery and shortcuts apply to the right
  thing.
  """

  @doc """
  The command line of the foreground process on the shell's terminal — the
  process group owning the tty (tpgid from `/proc/<pid>/stat`), e.g. a running
  CLI agent. Returns nil at a plain prompt (the shell owns the tty itself).
  """
  @spec cmdline(term()) :: String.t() | nil
  def cmdline(shell_pid) when is_integer(shell_pid) and shell_pid > 0 do
    with {:ok, stat} <- File.read("/proc/#{shell_pid}/stat"),
         [{idx, _len} | _] <- Enum.reverse(:binary.matches(stat, ")")),
         # Fields come after the last ")" (comm may itself contain parens).
         fields = stat |> binary_part(idx + 1, byte_size(stat) - idx - 1) |> String.split(),
         tpgid_s when is_binary(tpgid_s) <- Enum.at(fields, 5),
         {tpgid, ""} <- Integer.parse(tpgid_s),
         true <- tpgid > 0 and tpgid != shell_pid,
         {:ok, cmdline} <- File.read("/proc/#{tpgid}/cmdline"),
         cmd when cmd != "" <- cmdline |> String.split(<<0>>, trim: true) |> Enum.join(" ") do
      cmd
    else
      _unavailable -> nil
    end
  end

  def cmdline(_shell_pid), do: nil
end
