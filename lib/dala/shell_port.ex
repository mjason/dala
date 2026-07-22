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
  `"/dev/null"`). Windows helpers are hidden by default so background
  processes never open the system terminal. Extra `Port.open/2` options
  (`cd:`, line mode, …) are appended to the defaults.
  """
  def open([_ | _] = command, stderr, port_opts \\ []) do
    if windows?() do
      config = Jason.encode!(%{command: command, stderr: stderr})

      Port.open(
        {:spawn_executable, proxy_path()},
        port_options([{:args, ["exec", config]} | port_opts])
      )
    else
      Port.open(
        {:spawn_executable, "/bin/sh"},
        port_options([{:args, ["-c", shell_command(command, stderr)]} | port_opts])
      )
    end
  end

  @doc false
  def port_options(port_opts) when is_list(port_opts) do
    port_opts =
      if windows?() and :hide not in port_opts,
        do: [:hide | port_opts],
        else: port_opts

    [:binary, :exit_status, :use_stdio | port_opts]
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
    unless windows?() do
      case Port.info(port, :os_pid) do
        {:os_pid, os_pid} -> System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
        _ -> :ok
      end
    end

    Port.close(port)
    :ok
  catch
    _, _ -> :ok
  end

  defp proxy_path do
    Path.join([:code.priv_dir(:dala), "bin", "dala_holder.exe"])
  end

  defp windows?, do: match?({:win32, _}, :os.type())
end
