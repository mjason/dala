defmodule Dala.Terminal.Server do
  @moduledoc """
  BEAM-side owner of a terminal session, connected to its out-of-process PTY
  holder (`Dala.Terminal.Holder`) over a unix socket.

  The holder — not this process — owns the PTY and the shell, so shells
  survive dala restarts: on init this server reattaches to a live holder when
  one exists and only spawns a fresh shell otherwise. Output frames are
  broadcast to the `terminal:{id}` channel topic; history lives in the
  holder's embedded terminal emulator and is delivered as a synthesized
  repaint when a client attaches (`request_repaint/2`). Session lifecycle changes go through internal Ash actions so
  their PubSub publications reach the typed channels.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Dala.Terminal.Holder

  @cwd_poll_ms 2_000
  @force_stop_ms 5_000

  # Host-terminal identity leaked from the parent process would make shell
  # integrations and TUIs (opencode, …) negotiate protocols the web terminal
  # does not speak (ghostty/kitty extensions, …).
  @env_remove ~w(
    TERM_PROGRAM TERM_PROGRAM_VERSION
    GHOSTTY_RESOURCES_DIR GHOSTTY_BIN_DIR GHOSTTY_SHELL_INTEGRATION_NO_SUDO
    KITTY_WINDOW_ID KITTY_PID KITTY_INSTALLATION_DIR KITTY_PUBLIC_KEY
    WEZTERM_EXECUTABLE WEZTERM_CONFIG_FILE WEZTERM_PANE WEZTERM_UNIX_SOCKET
    ITERM_SESSION_ID LC_TERMINAL LC_TERMINAL_VERSION
    VTE_VERSION WT_SESSION WT_PROFILE_ID
    TMUX TMUX_PANE STY ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID
    VSCODE_INJECTION VSCODE_GIT_ASKPASS_NODE VSCODE_GIT_ASKPASS_MAIN VSCODE_GIT_IPC_HANDLE
  )

  # When the shell dies, whatever modes its programs had enabled (mouse
  # tracking, bracketed paste, alt-screen, hidden cursor) are stale on the
  # connected clients and would turn mouse movement into `35;36M`-style
  # input garbage — switch them all off.
  @mode_reset "\e[?1000l\e[?1002l\e[?1003l\e[?1005l\e[?1006l" <>
                "\e[?2004l\e[?1049l\e[?1l\e[?7h\e[?25h\e[0m"

  ## Client

  def ensure_started(%Dala.Terminal.Session{} = session) do
    case DynamicSupervisor.start_child(Dala.Terminal.ServerSupervisor, {__MODULE__, session}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  def start_link(session) do
    GenServer.start_link(__MODULE__, session, name: via(session.id))
  end

  @doc "Write keyboard input (raw bytes) to the PTY."
  def input(id, data), do: cast_if_alive(id, {:input, data})

  @doc """
  Reports a connected client's viewport size.

  A session is shared: several clients (desktop, phone, another tab) may be
  attached at once, but the single underlying PTY can only have one size. As
  in tmux/screen, the PTY is sized to the *smallest* connected viewport so
  its output never overflows the most constrained client. `client` is the
  channel process; the server tracks it and drops its size when it exits.
  """
  def resize(id, client, rows, cols) when is_pid(client),
    do: cast_if_alive(id, {:resize, client, rows, cols})

  @doc "Current PTY size as `{rows, cols}`, or nil if the session is not running."
  def viewport(id) do
    case whereis(id) do
      nil -> nil
      pid -> GenServer.call(pid, :viewport)
    end
  end

  @doc """
  The CLI agent (claude/opencode/codex/gemini/copilot) running in the
  foreground of this session, "shell" at a plain prompt, or "unknown".
  Sees through zellij/tmux via the focused pane's command.
  """
  def foreground_app(id) do
    case whereis(id) do
      nil -> {:error, "session is not running"}
      pid -> GenServer.call(pid, :foreground_app, 5_000)
    end
  end

  @doc """
  Detach other zellij/tmux clients of the multiplexer session this shell is
  attached to (they cap its size to the smallest window). See
  `Dala.Terminal.Viewers`.
  """
  def kick_viewers(id) do
    case whereis(id) do
      nil -> {:error, "session is not running"}
      pid -> GenServer.call(pid, :kick_viewers, 10_000)
    end
  end

  @doc """
  Asks the holder for a synthesized repaint and delivers it to `client` as a
  `{:repaint, data, seq}` message. `seq` is the seq of the last output the
  repaint covers, so the client can deduplicate the live stream against it.
  """
  def request_repaint(id, client) when is_pid(client),
    do: cast_if_alive(id, {:request_repaint, client})

  @doc "Kill the shell. The session is marked exited once the holder reports it."
  def stop(id), do: cast_if_alive(id, :shutdown)

  @doc """
  Kill the shell and block until the server has fully stopped (i.e. the exit
  has been recorded). Used before destroying a session so no output trickles
  into the scrollback cache after it is cleared.
  """
  def shutdown_and_wait(id, timeout \\ 10_000) do
    case whereis(id) do
      nil ->
        # No server, but a detached holder may still be running the shell.
        kill_detached_holder(to_string(id))

      pid ->
        ref = Process.monitor(pid)
        GenServer.cast(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          timeout ->
            Process.demonitor(ref, [:flush])
            :ok
        end
    end
  end

  def alive?(id), do: whereis(id) != nil

  def whereis(id) do
    case Registry.lookup(Dala.Terminal.Registry, to_string(id)) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp via(id), do: {:via, Registry, {Dala.Terminal.Registry, to_string(id)}}

  defp cast_if_alive(id, message) do
    case whereis(id) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end

  # Best-effort kill of a holder no server is attached to (session destroy
  # while dala never reattached after a restart).
  defp kill_detached_holder(id) do
    with {:ok, socket} <- Holder.connect(id) do
      Holder.send_kill(socket)
      :gen_tcp.close(socket)
    end

    :ok
  end

  ## Server

  @impl true
  def init(session) do
    id = to_string(session.id)

    opts = [
      shell: session.shell,
      cwd: session.cwd,
      env: [
        {"TERM", "xterm-256color"},
        {"COLORTERM", "truecolor"},
        # Advertise Warp's open cli-agent notification protocol: the agent
        # plugins (claude-code-warp, opencode-warp, …) emit OSC 777 events
        # only when these are present.
        {"WARP_CLI_AGENT_PROTOCOL_VERSION", "1"},
        {"WARP_CLIENT_VERSION", "dala"}
      ],
      env_remove: @env_remove,
      rows: 24,
      cols: 80,
      history_lines: history_lines(session.scrollback_limit)
    ]

    case Holder.attach_or_spawn(id, opts) do
      {:ok, socket, reattached?} ->
        state = %{
          id: id,
          session: session,
          socket: socket,
          # Filled in by the holder's HELLO frame.
          shell_pid: nil,
          cwd: session.cwd,
          # Monotonic across restarts so a rejoining client's dedup window
          # never sees the counter move backwards.
          seq: System.system_time(:millisecond),
          # Channels waiting for a holder repaint, in request order (the
          # holder answers over the same FIFO socket).
          pending_repaints: :queue.new(),
          # Per-client viewport sizes; the PTY tracks their minimum.
          clients: %{},
          # Once the stream reports cwd via OSC 7, /proc polling stops: the
          # top-level shell's cwd is stale inside zellij/tmux.
          osc7_cwd?: false,
          # zellij/tmux client detected under the shell — cwd then comes
          # from the multiplexer itself (focused pane), not OSC 7 or /proc.
          mux: nil,
          # Output micro-batching: the first chunk after idle is emitted
          # immediately (keystroke echo pays no extra latency); chunks that
          # land within the 5ms window after it — TUI redraw storms — are
          # coalesced into one broadcast.
          out_buf: [],
          out_timer: nil,
          size: {24, 80},
          reattached?: reattached?
        }

        {:ok, state, {:continue, :post_init}}

      {:error, reason} ->
        {:stop, {:holder_start_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:post_init, state) do
    state = %{state | session: Dala.Terminal.mark_running!(state.session)}
    Process.send_after(self(), :poll_cwd, @cwd_poll_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:viewport, _from, state) do
    {:reply, state.size, state}
  end

  @impl true
  def handle_call(:foreground_app, _from, state) do
    cmdline =
      case state.mux do
        nil ->
          Dala.Terminal.Viewers.foreground_cmdline(state.shell_pid)

        mux ->
          case Dala.Terminal.MuxCwd.focused_command(mux) do
            {:ok, command} -> command
            :error -> nil
          end
      end

    {:reply, {:ok, %{app: classify_app(cmdline), cmdline: cmdline || ""}}, state}
  end

  @impl true
  def handle_call(:kick_viewers, _from, state) do
    {:reply, Dala.Terminal.Viewers.kick_others(state.shell_pid), state}
  end

  @impl true
  def terminate(_reason, state) do
    # Deliberately leaves the holder (and thus the shell) running: surviving
    # BEAM shutdowns and code reloads is the point of the holder split.
    # Explicit kills go through handle_cast(:shutdown) instead.
    if state.socket, do: :gen_tcp.close(state.socket)
    :ok
  rescue
    _error -> :ok
  end

  @impl true
  def handle_cast({:input, data}, state) do
    _ = Holder.send_input(state.socket, data)
    {:noreply, state}
  end

  def handle_cast({:resize, client, rows, cols}, state) do
    # Monitor each client the first time we hear from it, so its size is
    # dropped when the channel process exits.
    unless Map.has_key?(state.clients, client), do: Process.monitor(client)

    clients = Map.put(state.clients, client, {rows, cols})
    {:noreply, apply_min_size(%{state | clients: clients})}
  end

  def handle_cast({:request_repaint, client}, state) do
    # The requester's own viewport width decides soft vs hard wrapping in
    # the repaint; an unknown client inherits the PTY width.
    cols =
      case Map.get(state.clients, client) do
        {_rows, cols} -> cols
        nil -> elem(state.size, 1)
      end

    case Holder.send_repaint_req(state.socket, cols) do
      :ok ->
        {:noreply, %{state | pending_repaints: :queue.in(client, state.pending_repaints)}}

      {:error, _reason} ->
        # Holder unreachable — answer empty so the client is not left covered.
        send(client, {:repaint, "", state.seq})
        {:noreply, state}
    end
  end

  def handle_cast(:shutdown, state) do
    _ = Holder.send_kill(state.socket)
    Process.send_after(self(), :force_stop, @force_stop_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, socket, <<frame_type, payload::binary>>}, %{socket: socket} = state) do
    handle_frame(frame_type, payload, state)
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    # The holder vanished without an EXIT frame (crash, or it kicked us for a
    # newer client). Its exit file has the status when the shell died.
    exit_with_status(Holder.take_exit_status(state.id), %{state | socket: nil})
  end

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state) do
    exit_with_status(Holder.take_exit_status(state.id), %{state | socket: nil})
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state)
      when is_map_key(state.clients, pid) do
    # A client disconnected — drop its size so a larger remaining client can
    # reclaim the PTY dimensions.
    {:noreply, apply_min_size(%{state | clients: Map.delete(state.clients, pid)})}
  end

  def handle_info(:force_stop, state) do
    # The holder did not report an exit within the timeout after kill.
    case Dala.Terminal.mark_exited(state.session, %{exit_code: nil}) do
      {:ok, _session} -> :ok
      {:error, error} -> Logger.warning("could not mark session exited: #{inspect(error)}")
    end

    {:stop, :normal, state}
  end

  def handle_info(:flush_output, state) do
    {:noreply, flush_buffer(%{state | out_timer: nil})}
  end

  def handle_info(:poll_cwd, state) do
    {state, cwd} = poll_cwd_once(state)
    state = if cwd, do: apply_cwd(state, cwd), else: state

    Process.send_after(self(), :poll_cwd, @cwd_poll_ms)
    {:noreply, state}
  end

  # zellij/tmux never forward their panes' OSC 7 and their shells live under
  # a detached server invisible to /proc — while a multiplexer client runs in
  # this session, ask the multiplexer itself for the focused pane's cwd.
  # Detection (one ps scan) runs every tick while no mux is known, so
  # entering zellij/tmux is picked up within a poll interval; a failing query
  # (the mux session died) falls back to detection on the next tick.
  defp poll_cwd_once(%{mux: nil} = state) do
    case Dala.Terminal.Viewers.find_mux(state.shell_pid) do
      nil ->
        {state, if(state.osc7_cwd?, do: nil, else: current_cwd(state.shell_pid))}

      mux ->
        case Dala.Terminal.MuxCwd.cwd(mux) do
          {:ok, cwd} -> {%{state | mux: mux}, cwd}
          :error -> {state, nil}
        end
    end
  end

  defp poll_cwd_once(%{mux: mux} = state) do
    case Dala.Terminal.MuxCwd.cwd(mux) do
      {:ok, cwd} -> {state, cwd}
      :error -> {%{state | mux: nil}, nil}
    end
  end

  defp apply_cwd(state, cwd) when cwd == state.cwd, do: state

  defp apply_cwd(state, cwd) do
    if File.dir?(cwd) do
      case Dala.Terminal.update_cwd(state.session, %{cwd: cwd}) do
        {:ok, session} -> %{state | cwd: cwd, session: session}
        {:error, _error} -> state
      end
    else
      state
    end
  end

  defp handle_frame(frame_type, payload, state) do
    cond do
      frame_type == Holder.type_output() ->
        {:noreply, buffer_output(state, payload)}

      frame_type == Holder.type_cwd() ->
        # OSC 7 from the stream. While a multiplexer runs, only its own
        # top-level shell can reach us (panes are not forwarded), so its
        # report would be stale — the mux poll is authoritative then.
        if state.mux do
          {:noreply, %{state | osc7_cwd?: true}}
        else
          {:noreply, apply_cwd(%{state | osc7_cwd?: true}, payload)}
        end

      frame_type == Holder.type_agent() ->
        broadcast_agent_event(state, payload)
        {:noreply, state}

      frame_type == Holder.type_repaint() ->
        state = flush_now(state)

        # The socket is FIFO: every output the repaint covers has already
        # been processed, so state.seq is exactly the repaint's watermark.
        case :queue.out(state.pending_repaints) do
          {{:value, client}, rest} ->
            send(client, {:repaint, payload, state.seq})
            {:noreply, %{state | pending_repaints: rest}}

          {:empty, _queue} ->
            {:noreply, state}
        end

      frame_type == Holder.type_hello() ->
        shell_pid =
          case Jason.decode(payload) do
            {:ok, %{"pid" => pid}} when is_integer(pid) and pid > 0 -> pid
            _other -> nil
          end

        # The holder sized the PTY at spawn time; make sure a reattached one
        # matches the currently connected clients.
        {:noreply, apply_min_size(%{state | shell_pid: shell_pid}, force: true)}

      frame_type == Holder.type_exit() ->
        <<status::32>> = payload
        exit_with_status(status, state)

      true ->
        {:noreply, state}
    end
  end

  defp exit_with_status(status, state) do
    state = flush_now(state)
    # Whatever was running is gone; make sure connected clients drop its
    # mouse/paste/alt-screen modes.
    _ = emit(state, @mode_reset)

    if state.session.ephemeral do
      # Quick shells vanish on exit instead of lingering as "exited".
      # Destroy from outside this process: CleanupSession waits for this
      # server to stop, which we are about to do.
      session = state.session

      Task.start(fn ->
        case Dala.Terminal.delete_session(session) do
          :ok ->
            :ok

          {:error, error} ->
            Logger.warning("could not destroy quick shell #{session.id}: #{inspect(error)}")
        end
      end)
    else
      case Dala.Terminal.mark_exited(state.session, %{exit_code: status}) do
        {:ok, _session} ->
          :ok

        {:error, error} ->
          Logger.warning("could not mark session #{state.id} exited: #{inspect(error)}")
      end
    end

    {:stop, :normal, state}
  end

  defp current_cwd(nil), do: nil

  defp current_cwd(shell_pid) do
    case File.read_link("/proc/#{shell_pid}/cwd") do
      {:ok, cwd} -> cwd
      {:error, _reason} -> nil
    end
  end

  # Sizes the PTY to the smallest connected client's viewport. No-op while no
  # clients are attached (keep the last size) or when the minimum is unchanged.
  defp apply_min_size(state, opts \\ []) do
    case Map.values(state.clients) do
      [] ->
        state

      sizes ->
        rows = sizes |> Enum.map(&elem(&1, 0)) |> Enum.min()
        cols = sizes |> Enum.map(&elem(&1, 1)) |> Enum.min()
        size = {rows, cols}

        if size == state.size and not Keyword.get(opts, :force, false) do
          state
        else
          _ = Holder.send_resize(state.socket, rows, cols)
          # Tell every attached client the new PTY size. Desktop clients that
          # drive their own size ignore it; "follower" clients (e.g. a phone
          # watching a desktop session) render at this size and scale to fit.
          DalaWeb.Endpoint.broadcast("terminal:" <> state.id, "resize", %{rows: rows, cols: cols})
          %{state | size: size}
        end
    end
  end

  # Broadcasts an output chunk to connected clients with the next seq.
  # OSC agent notifications from the holder: `title \x1f body`. Structured
  # events (title `warp://cli-agent`, Warp's open protocol) carry a JSON
  # payload from the agent's plugin hooks; OSC 9 ("osc9") and generic OSC 777
  # notifications become plain "notify"/"stop" events. Broadcast on the
  # sessions lobby so the client can notify for background sessions too.
  defp broadcast_agent_event(state, payload) do
    case parse_agent_event(payload) do
      nil ->
        Logger.debug(
          "agent event unparsed (#{state.id}): #{inspect(payload, printable_limit: 200)}"
        )

      event ->
        Logger.debug("agent event (#{state.id}): #{event.agent}/#{event.event}")
        DalaWeb.Endpoint.broadcast("sessions", "agent_event", Map.put(event, :id, state.id))
    end
  end

  defp parse_agent_event(payload) do
    case :binary.split(payload, <<0x1F>>) do
      ["warp://cli-agent", body] ->
        case Jason.decode(body) do
          {:ok, %{"event" => event} = raw} ->
            %{
              agent: raw["agent"] || "unknown",
              event: event,
              project: raw["project"],
              summary: raw["summary"],
              query: raw["query"],
              response: raw["response"],
              toolName: raw["tool_name"],
              toolInput: tool_preview(raw["tool_input"])
            }

          _ ->
            nil
        end

      ["osc9", body] ->
        %{
          agent: "unknown",
          event: "notify",
          summary: body,
          project: nil,
          query: nil,
          response: nil,
          toolName: nil,
          toolInput: nil
        }

      [title, body] ->
        %{
          agent: "unknown",
          event: "notify",
          summary: "#{title}: #{body}",
          project: nil,
          query: nil,
          response: nil,
          toolName: nil,
          toolInput: nil
        }

      _ ->
        nil
    end
  end

  defp tool_preview(%{"command" => command}) when is_binary(command), do: command
  defp tool_preview(%{"file_path" => path}) when is_binary(path), do: path
  defp tool_preview(%{"filePath" => path}) when is_binary(path), do: path
  defp tool_preview(_), do: nil

  # Warp's rich-input strategies are per agent; the client picks one based
  # on this classification.
  defp classify_app(nil), do: "shell"

  defp classify_app(cmdline) do
    down = String.downcase(cmdline)

    cond do
      down =~ "claude" -> "claude"
      down =~ "opencode" -> "opencode"
      down =~ "codex" -> "codex"
      down =~ "gemini" -> "gemini"
      down =~ "copilot" -> "copilot"
      true -> "unknown"
    end
  end

  defp buffer_output(state, data) do
    if state.out_timer do
      %{state | out_buf: [data | state.out_buf]}
    else
      timer = Process.send_after(self(), :flush_output, 5)
      %{emit(state, data) | out_timer: timer}
    end
  end

  defp flush_buffer(%{out_buf: []} = state), do: state

  defp flush_buffer(state) do
    data = state.out_buf |> Enum.reverse() |> IO.iodata_to_binary()
    emit(%{state | out_buf: []}, data)
  end

  defp flush_now(state) do
    if state.out_timer, do: Process.cancel_timer(state.out_timer)
    flush_buffer(%{state | out_timer: nil})
  end

  defp emit(state, data) do
    seq = state.seq + 1

    DalaWeb.Endpoint.broadcast("terminal:" <> state.id, "output", %{
      data: Base.encode64(data),
      seq: seq
    })

    %{state | seq: seq}
  end

  # The limit is emulator history lines; values above 100k are legacy byte
  # limits from the retired DETS cache (~120 bytes/line converts them).
  defp history_lines(limit) when is_integer(limit) and limit > 100_000,
    do: (limit / 120) |> round() |> max(1_000) |> min(50_000)

  defp history_lines(limit) when is_integer(limit) and limit > 0,
    do: limit |> max(1_000) |> min(50_000)

  defp history_lines(_other), do: 10_000
end
