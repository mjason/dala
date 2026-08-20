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
    case :os.type() do
      {:win32, :nt} ->
        shell = System.get_env("ComSpec") || System.find_executable("cmd.exe") || "cmd.exe"
        command_line = windows_command(command, stderr)
        port_opts = if :hide in port_opts, do: port_opts, else: [:hide | port_opts]

        Port.open(
          {:spawn_executable, shell},
          [
            :binary,
            :exit_status,
            args: ["/d", "/c", "%DALA_SHELL_COMMAND%"],
            env: [{~c"DALA_SHELL_COMMAND", String.to_charlist(command_line)}]
          ] ++ port_opts
        )

      _ ->
        Port.open(
          {:spawn_executable, "/bin/sh"},
          [:binary, :exit_status, args: ["-c", shell_command(command, stderr)]] ++ port_opts
        )
    end
  end

  @doc "Runs a command through a killable port and enforces a hard deadline."
  def run([_ | _] = command, stderr, timeout, port_opts \\ [])
      when is_integer(timeout) and timeout > 0 do
    port = open(command, stderr, port_opts)
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, [], deadline)
  end

  @doc "The `sh -c` command string: escaped argv `exec`'d, stderr redirected."
  def shell_command(command, stderr) do
    Enum.map_join(["exec" | command], " ", &escape/1) <> " 2> " <> escape(stderr)
  end

  defp windows_command(command, stderr) do
    stderr = if stderr == "/dev/null", do: "NUL", else: stderr
    Enum.map_join(command, " ", &windows_escape/1) <> " 2> " <> windows_escape(stderr)
  end

  defp windows_escape(word) do
    value = String.replace(to_string(word), ~r/([\^&|<>()%!"])/, "^\\1")

    if value == "" or value =~ ~r/[\s,;=\^&|<>()%!"]/, do: "\"#{value}\"", else: value
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
      {:os_pid, os_pid} -> terminate_os_process(os_pid)
      _ -> :ok
    end

    Port.close(port)
    :ok
  catch
    _, _ -> :ok
  end

  defp terminate_os_process(os_pid) do
    case :os.type() do
      {:win32, :nt} -> System.cmd("taskkill", ["/PID", Integer.to_string(os_pid), "/T", "/F"])
      _ -> System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
    end
  end

  defp collect(port, chunks, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, [data | chunks], deadline)

      {^port, {:exit_status, status}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      remaining ->
        close(port)
        {:error, :timeout}
    end
  end
end
