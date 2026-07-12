defmodule Dala.ShellPort do
  @moduledoc """
  Ports wrapped in `/bin/sh -c "exec …"`, for external programs that need
  their stderr redirected: a port child inherits the BEAM's stderr, and a
  lingering process holding that fd keeps pipes (`mix test | tail`) open
  forever. `exec` keeps the program itself — not the wrapper shell — as the
  port's os_pid, so it can be signalled on teardown.
  """

  @doc """
  Opens a port running `command` (an argv list) through the shell wrapper,
  with stderr redirected to the `stderr` path (a capture file or
  `"/dev/null"`). Extra `Port.open/2` options (`:hide`, `cd:`, …) are
  appended to the defaults (`:binary`, `:exit_status`).
  """
  def open([_ | _] = command, stderr, port_opts \\ []) do
    Port.open(
      {:spawn_executable, "/bin/sh"},
      [:binary, :exit_status, args: ["-c", shell_command(command, stderr)]] ++ port_opts
    )
  end

  @doc "The `sh -c` command string: escaped argv `exec`'d, stderr redirected."
  def shell_command(command, stderr) do
    Enum.map_join(["exec" | command], " ", &escape/1) <> " 2> " <> escape(stderr)
  end

  @doc "Single-quote shell escaping of one word."
  def escape(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  @doc """
  Tears a port down, killing its OS process. `Port.close/1` only closes
  stdio; since the wrapper shell `exec`'d the program, the port's os_pid IS
  the program — ask it to die too. Safe on `nil` and already-dead ports.
  """
  def close(nil), do: :ok

  def close(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
      _ -> :ok
    end

    Port.close(port)
    :ok
  catch
    _, _ -> :ok
  end
end
