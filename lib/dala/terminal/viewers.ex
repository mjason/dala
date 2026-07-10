defmodule Dala.Terminal.Viewers do
  @moduledoc """
  "Kick other viewers" for multiplexer sessions.

  zellij and tmux size a session to their *smallest* attached client, so a
  forgotten attachment elsewhere (an SSH window, another terminal) letterboxes
  this one. Given the session's shell pid, this walks its process tree to find
  the zellij/tmux client it runs, resolves the multiplexer session, and
  detaches every other client of that session — leaving ours the only one.
  """

  @doc "Detach all other clients of the zellij/tmux session under `shell_pid`."
  def kick_others(shell_pid) when is_integer(shell_pid) and shell_pid > 0 do
    procs = list_procs()
    subtree = descendants(procs, shell_pid)

    case find_client(procs, subtree) do
      {:zellij, name, own_pid} -> kick_zellij(procs, subtree, name, own_pid)
      {:tmux, own_pid} -> kick_tmux(own_pid)
      nil -> {:error, "no zellij/tmux client is running in this session"}
    end
  end

  def kick_others(_), do: {:error, "shell is not running"}

  @doc """
  The multiplexer client running under `shell_pid`, if any:
  `{:zellij, session_name}` | `{:tmux, client_pid}` | `nil`. Used by cwd
  polling to ask the multiplexer (instead of /proc) where the user is.
  """
  def find_mux(shell_pid) when is_integer(shell_pid) and shell_pid > 0 do
    procs = list_procs()

    case find_client(procs, descendants(procs, shell_pid)) do
      {:zellij, name, _own_pid} -> {:zellij, name}
      {:tmux, own_pid} -> {:tmux, own_pid}
      nil -> nil
    end
  end

  def find_mux(_), do: nil

  defp kick_zellij(procs, subtree, name, own_pid) do
    victims =
      for {pid, _ppid, args} <- procs,
          pid != own_pid,
          pid not in subtree,
          zellij_session(args) == name,
          do: pid

    Enum.each(victims, &kill/1)
    {:ok, %{multiplexer: "zellij", session: name, kicked: length(victims)}}
  end

  # tmux has a first-class API for this: list the clients of the default
  # server and detach every tty that is not ours (scoped to our session
  # when we can tell which one that is).
  defp kick_tmux(own_pid) do
    format = "\#{client_pid} \#{client_tty} \#{client_session}"

    case System.cmd("tmux", ["list-clients", "-F", format], stderr_to_stdout: true) do
      {out, 0} ->
        clients =
          for line <- String.split(out, "\n", trim: true),
              [pid, tty, session] <- [String.split(line, " ", parts: 3)],
              do: {String.to_integer(pid), tty, session}

        own_session =
          Enum.find_value(clients, fn {pid, _tty, session} ->
            if pid == own_pid, do: session
          end)

        victims =
          for {pid, tty, session} <- clients,
              pid != own_pid,
              own_session == nil or session == own_session,
              do: tty

        Enum.each(victims, fn tty ->
          System.cmd("tmux", ["detach-client", "-t", tty], stderr_to_stdout: true)
        end)

        {:ok, %{multiplexer: "tmux", session: own_session || "", kicked: length(victims)}}

      {out, _} ->
        {:error, "tmux: #{String.trim(out)}"}
    end
  end

  defp find_client(procs, subtree) do
    Enum.find_value(procs, fn {pid, _ppid, args} ->
      if pid in subtree do
        case zellij_session(args) do
          nil -> if tmux_client?(args), do: {:tmux, pid}
          name -> {:zellij, name, pid}
        end
      end
    end)
  end

  # The zellij session name from a client's command line: `zellij attach X`,
  # `zellij a X`, `zellij -s X`, `zellij --session X`. Returns nil for the
  # zellij *server* (`zellij --server …`) and for plain `zellij` (random
  # session name we cannot know from args alone).
  defp zellij_session(args) do
    case String.split(args) do
      [bin | rest] ->
        if String.ends_with?(bin, "zellij") and "--server" not in rest do
          session_from_tokens(rest)
        end

      _ ->
        nil
    end
  end

  defp session_from_tokens(["attach" | rest]), do: first_positional(rest)
  defp session_from_tokens(["a" | rest]), do: first_positional(rest)
  defp session_from_tokens(["-s", name | _]), do: name
  defp session_from_tokens(["--session", name | _]), do: name
  defp session_from_tokens([_ | rest]), do: session_from_tokens(rest)
  defp session_from_tokens([]), do: nil

  defp first_positional([<<"-", _::binary>> | rest]), do: first_positional(rest)
  defp first_positional([name | _]), do: name
  defp first_positional([]), do: nil

  # Any tmux process inside the shell's subtree is our client — the tmux
  # server daemonizes and reparents to init, so it never appears here.
  defp tmux_client?(args) do
    case String.split(args) do
      [bin | _] -> String.ends_with?(bin, "tmux")
      _ -> false
    end
  end

  defp kill(pid), do: System.cmd("kill", [Integer.to_string(pid)], stderr_to_stdout: true)

  defp list_procs do
    {out, 0} = System.cmd("ps", ["-eo", "pid=,ppid=,args="])

    for line <- String.split(out, "\n", trim: true),
        [pid, ppid | args] = String.split(String.trim(line), " ", trim: true),
        args != [] do
      {String.to_integer(pid), String.to_integer(ppid), Enum.join(args, " ")}
    end
  end

  # The shell's pid plus every (transitive) child.
  defp descendants(procs, root) do
    children =
      Enum.reduce(procs, %{}, fn {pid, ppid, _}, acc ->
        Map.update(acc, ppid, [pid], &[pid | &1])
      end)

    walk = fn walk, pid, acc ->
      Enum.reduce(Map.get(children, pid, []), MapSet.put(acc, pid), fn child, acc2 ->
        walk.(walk, child, acc2)
      end)
    end

    walk.(walk, root, MapSet.new())
  end
end
