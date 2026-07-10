defmodule Dala.Terminal.MuxCwd do
  @moduledoc """
  Working directory of the *focused pane* inside a zellij/tmux session.

  Multiplexers do not forward OSC 7 from their panes to the host terminal,
  and /proc only sees the top-level shell — so once the user is inside
  zellij/tmux, both existing cwd sources go blind. The multiplexers do know
  every pane's cwd though: zellij serializes it in `action dump-layout`,
  tmux exposes `pane_current_path`. Queries run under a short timeout so a
  wedged multiplexer can never stall the terminal server.
  """

  @timeout_ms 1_500

  @doc "Focused-pane cwd for the given mux (`Viewers.find_mux/1` result)."
  def cwd({:zellij, session}) do
    with {:ok, layout} <- run("zellij", ["--session", session, "action", "dump-layout"]) do
      focused_cwd(layout)
    end
  end

  def cwd({:tmux, client_pid}) do
    with {:ok, out} <-
           run("tmux", [
             "display-message",
             "-c",
             tty_of(client_pid),
             "-p",
             "\#{pane_current_path}"
           ]),
         cwd when cwd != "" <- String.trim(out) do
      {:ok, cwd}
    else
      _ -> :error
    end
  end

  def cwd(_), do: :error

  # --- zellij layout parsing ------------------------------------------------
  #
  # dump-layout is KDL. The session-level `cwd "/base"` node factors out the
  # common prefix; a pane whose directory differs carries an inline
  # `cwd="dir"` property (absolute, or relative to the base). Focus is marked
  # on the tab and down the pane tree — the innermost focused pane line wins.
  defp focused_cwd(layout) do
    base =
      case Regex.run(~r/^\s*cwd "([^"]+)"/m, layout) do
        [_, base] -> base
        _ -> nil
      end

    tab = focused_tab_body(layout)

    pane_cwd =
      ~r/^\s*pane\b[^\n]*\bfocus=true[^\n]*$/m
      |> Regex.scan(tab, capture: :first)
      |> List.flatten()
      |> Enum.reverse()
      |> Enum.find_value(fn line ->
        case Regex.run(~r/\bcwd="([^"]+)"/, line) do
          [_, cwd] -> cwd
          _ -> nil
        end
      end)

    case {pane_cwd, base} do
      {nil, nil} -> :error
      {nil, base} -> {:ok, base}
      {"/" <> _ = abs, _} -> {:ok, abs}
      {rel, nil} -> {:ok, "/" <> rel}
      {rel, base} -> {:ok, Path.join(base, rel)}
    end
  end

  # The body of the `tab … focus=true` node, brace-balanced. Falls back to
  # the whole layout for single-tab dumps or parser misses.
  defp focused_tab_body(layout) do
    case Regex.run(~r/^\s*tab\b[^\n]*\bfocus=true[^\n]*\{/m, layout, return: :index) do
      [{start, len}] -> balanced_block(layout, start + len)
      _ -> layout
    end
  end

  defp balanced_block(text, from), do: balanced_block(text, from, 1, from)

  defp balanced_block(text, pos, depth, start) do
    case String.at(text, pos) do
      nil -> String.slice(text, start, pos - start)
      "{" -> balanced_block(text, pos + 1, depth + 1, start)
      "}" when depth == 1 -> String.slice(text, start, pos - start)
      "}" -> balanced_block(text, pos + 1, depth - 1, start)
      _ -> balanced_block(text, pos + 1, depth, start)
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp tty_of(pid) do
    case File.read_link("/proc/#{pid}/fd/0") do
      {:ok, tty} -> tty
      _ -> ""
    end
  end

  # System.cmd with a hard timeout: the poll loop must never hang on a
  # wedged multiplexer server.
  defp run(bin, args) do
    task =
      Task.async(fn ->
        try do
          System.cmd(bin, args, stderr_to_stdout: true)
        rescue
          # missing binary etc. — must not take the linked caller down
          _ -> :error
        end
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> {:ok, out}
      _ -> :error
    end
  end
end
