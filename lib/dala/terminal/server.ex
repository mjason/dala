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
  # Hard bounds on the PTY size, applied at the single choke point every
  # resize funnels through (apply_size/4). The channel clamps its inputs too,
  # but the holder allocates a rows×cols cell grid on resize — an unclamped
  # huge value (65535×65535) is a multi-GB allocation that aborts the holder
  # and hangs up the PTY under the running shell, so no caller may bypass
  # this. The holder clamps to the same bounds as a last line of defense.
  @min_rows 2
  @max_rows 500
  @min_cols 2
  @max_cols 1000
  # Output micro-batching window: chunks landing within it after the first
  # are coalesced into one broadcast (see buffer_output/2).
  @out_batch_ms 5
  # MCP wraps this text in JSON and then in an MCP text content string, so a
  # 64 KiB UTF-8 payload keeps the final wire response bounded after escaping.
  @snapshot_max_bytes 64 * 1024
  @wait_timeout_max_ms 25_000
  @waiters_per_session 8
  @match_buffer_bytes 128 * 1024

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
  Enqueue one complete rich-input delivery. Frames from separate callers are
  never interleaved; the returned sequence is captured immediately before the
  first frame reaches the holder.
  """
  def send_sequence(id, frames) when is_list(frames) do
    case whereis(id) do
      nil -> {:error, "session is not running"}
      pid -> GenServer.call(pid, {:send_sequence, frames}, 30_000)
    end
  catch
    :exit, {:timeout, _call} -> {:error, "terminal input queue timed out"}
  end

  @doc """
  Reports a connected client's viewport size.

  A session is shared: several clients (desktop, phone, another tab) may be
  attached at once, but the single underlying PTY can only have one size —
  and it is DEVICE-sticky: the session remembers which device
  (`size_owner_device`, persisted on the session record) owns its size. The
  first device to ever resize an unowned session adopts it; any connection
  from the remembered device silently (re)becomes the live owner, so
  reloads and reconnects stay zero-friction. A DIFFERENT device's resize is
  NEVER applied — not even when no live owner exists — until it explicitly
  takes over via `claim_size/6`, which also rewrites the device memory.
  `client` is the channel process, `client_ref` its public identity used in
  `size_owner` broadcasts and join replies, `device_id` the stable device
  identity the ownership sticks to.

  `device_id` may be NIL (legacy clients that never send one): those get
  the old per-connection model — the first resize with no live owner and
  no remembered device makes them the LIVE owner, but nil is never adopted
  into the device memory (a nil memory must also never read as "same
  device"), so nothing outlives their connection and the next client is
  never locked out by a ghost device.

  Synchronous, so the caller learns what happened: `:claimed` (this device
  adopted or re-took the size), `:applied` (the caller already was the live
  owner), or `{:ignored, %{owner: ref | nil, owner_device: device, rows:
  rows, cols: cols}}` when another device holds the size — the channel uses
  that to push a corrective `size_owner` to a client that wrongly believes
  it drives the size. `:ok` when the session is not running.
  """
  def resize(id, client, client_ref, device_id, rows, cols) when is_pid(client) do
    case whereis(id) do
      nil -> :ok
      pid -> GenServer.call(pid, {:resize, client, client_ref, device_id, rows, cols})
    end
  end

  @doc """
  Force-claims size ownership (the follower banner's takeover button): sets
  `client` as the live owner, makes `device_id` the remembered owner
  device, resizes the PTY, and broadcasts `size_owner` + `resize` so every
  attached client learns its new role. Last write wins on concurrent
  claims.
  """
  def claim_size(id, client, client_ref, device_id, rows, cols) when is_pid(client),
    do: cast_if_alive(id, {:claim_size, client, client_ref, device_id, rows, cols})

  @doc """
  Ownership + size snapshot for join replies:
  `%{owner: client_ref | nil, owner_device: device | nil, rows: rows,
  cols: cols}`, or nil if the session is not running.
  """
  def size_info(id) do
    case whereis(id) do
      nil -> nil
      pid -> GenServer.call(pid, :size_info)
    end
  end

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

  @doc "A bounded machine-readable plain-text snapshot of the terminal."
  def snapshot(id, opts \\ []) do
    lines = Keyword.get(opts, :lines, 200)
    lines = if lines == 0, do: 0, else: lines |> max(1) |> min(50_000)

    max_bytes =
      Keyword.get(opts, :max_bytes, @snapshot_max_bytes)
      |> max(1)
      |> min(@snapshot_max_bytes)

    case whereis(id) do
      nil ->
        with {:ok, snapshot} <- Holder.read_final_text(to_string(id)) do
          {:ok, Map.put(snapshot, "seq", 0)}
        else
          _ -> {:error, "plain-text snapshot is unavailable"}
        end

      pid ->
        GenServer.call(pid, {:text_snapshot, lines, max_bytes}, 6_000)
    end
  catch
    :exit, {:timeout, _call} -> {:error, "terminal snapshot timed out"}
  end

  @doc "The current terminal event sequence, or an error if it is not running."
  def current_seq(id) do
    case whereis(id) do
      nil -> {:error, "session is not running"}
      pid -> GenServer.call(pid, :current_seq)
    end
  end

  @doc "Wait atomically for terminal output, an agent event, exit, or timeout."
  def wait(id, after_seq, opts \\ []) when is_integer(after_seq) and after_seq >= 0 do
    timeout =
      Keyword.get(opts, :timeout, @wait_timeout_max_ms)
      |> max(1)
      |> min(@wait_timeout_max_ms)

    events =
      Keyword.get(opts, :events, ~w(output idle question permission stop exit))
      |> MapSet.new()

    case whereis(id) do
      nil ->
        {:ok, %{reason: "exit", seq: after_seq}}

      pid ->
        GenServer.call(
          pid,
          {:wait, after_seq, timeout, events, Keyword.get(opts, :match)},
          timeout + 2_000
        )
    end
  catch
    :exit, {:timeout, _call} -> {:error, "terminal wait timed out"}
  end

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
      rows: 24,
      cols: 80,
      history_lines: Dala.Terminal.Session.history_lines(session.scrollback_limit)
    ]

    case Holder.attach_or_spawn(id, opts) do
      {:ok, socket, reattached?} ->
        initial_seq = System.system_time(:millisecond)

        state = %{
          id: id,
          session: session,
          socket: socket,
          # Filled in by the holder's HELLO frame.
          shell_pid: nil,
          cwd: session.cwd,
          # Monotonic across restarts so a rejoining client's dedup window
          # never sees the counter move backwards.
          seq: initial_seq,
          last_output_seq: initial_seq,
          # Channels waiting for a holder repaint, in request order (the
          # holder answers over the same FIFO socket).
          pending_repaints: :queue.new(),
          # Machine snapshots use the holder's FIFO response queue.
          pending_text_snapshots: :queue.new(),
          holder_proto: nil,
          # Bounded long polls used by MCP. Waiters hold GenServer.from values
          # and are released by output, agent events, exit, timeout or caller
          # death without blocking this process.
          waiters: %{},
          recent_agent_events: [],
          # Bounded raw chunks cover the read -> wait registration race for
          # substring matching without rebuilding the emulator on each chunk.
          recent_output: [],
          match_filter_state: :text,
          input_jobs: :queue.new(),
          input_active: nil,
          # Monitored client channel pids -> their public client_ref.
          clients: %{},
          # The LIVE size owner as {pid, client_ref}, or nil. Only the
          # owner's resize reaches the PTY.
          owner: nil,
          # The remembered owner DEVICE (persisted on the session record):
          # ownership is device-sticky. nil until the first device ever
          # attaches/resizes (which adopts the session).
          size_owner_device: session.size_owner_device,
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
    state = %{state | session: Dala.Terminal.mark_running!(refresh_session(state))}
    Process.send_after(self(), :poll_cwd, @cwd_poll_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:viewport, _from, state) do
    {:reply, state.size, state}
  end

  @impl true
  def handle_call(:size_info, _from, state) do
    {:reply, ownership_snapshot(state), state}
  end

  def handle_call(:current_seq, _from, state), do: {:reply, {:ok, state.seq}, state}

  def handle_call({:text_snapshot, _lines, _max_bytes}, _from, %{holder_proto: proto} = state)
      when is_integer(proto) and proto < 3 do
    {:reply, {:error, "restart this session to enable plain-text terminal snapshots"}, state}
  end

  def handle_call({:text_snapshot, lines, max_bytes}, from, state) do
    case Holder.send_text_snapshot_req(state.socket, lines, max_bytes) do
      :ok ->
        pending = :queue.in({:caller, from}, state.pending_text_snapshots)
        {:noreply, %{state | pending_text_snapshots: pending}}

      {:error, _reason} ->
        {:reply, {:error, "terminal holder is unavailable"}, state}
    end
  end

  def handle_call({:wait, after_seq, timeout, events, match}, from, state) do
    cond do
      immediate_agent = matching_agent_event(state.recent_agent_events, after_seq, events) ->
        {:reply, {:ok, waiter_agent_result(immediate_agent)}, state}

      state.last_output_seq > after_seq and MapSet.member?(events, "output") and is_nil(match) ->
        {:reply, {:ok, %{reason: "output", seq: state.seq}}, state}

      is_binary(match) and MapSet.member?(events, "output") and
          recent_output_matches?(state, after_seq, match) ->
        {:reply, {:ok, %{reason: "match", seq: state.seq, match: match}}, state}

      map_size(state.waiters) >= @waiters_per_session ->
        {:reply, {:error, "too many terminal waiters for this session"}, state}

      true ->
        register_waiter(state, from, after_seq, timeout, events, match)
    end
  end

  def handle_call({:send_sequence, frames}, from, state) do
    jobs = :queue.in({from, frames}, state.input_jobs)
    {:noreply, start_next_input_job(%{state | input_jobs: jobs})}
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

    {:reply,
     {:ok, %{app: Dala.Terminal.AgentEvent.classify_app(cmdline), cmdline: cmdline || ""}}, state}
  end

  @impl true
  def handle_call(:kick_viewers, _from, state) do
    {:reply, Dala.Terminal.Viewers.kick_others(state.shell_pid), state}
  end

  @impl true
  def handle_call({:resize, client, client_ref, device_id, rows, cols}, _from, state) do
    state = track_client(state, client, client_ref)

    cond do
      match?({^client, _ref}, state.owner) ->
        {:reply, :applied, apply_size(state, rows, cols)}

      # Guard order matters for nil devices: only a NON-nil device may
      # adopt or silently re-own — a nil device must neither be remembered
      # nor read a nil memory as "same device" (it would ghost-lock or
      # steal sessions for every legacy client at once).
      (device_id != nil and
         (state.size_owner_device == nil or device_id == state.size_owner_device)) or
          (device_id == nil and state.size_owner_device == nil and state.owner == nil) ->
        # Devices: the first attach EVER adopts the session (a phone
        # creating a session gets a native narrow PTY this way); the
        # remembered device silently re-owns on reconnect — even past a
        # lingering connection of its own (reload race). Nil devices
        # (legacy clients): old per-connection model — free ownership
        # (no live owner, no memory) goes to the first resize, and
        # remember_device/2 skips nil so nothing persists. When the claim
        # actually CHANGED the PTY dims the grid was rewrapped — push a
        # fresh snapshot to every client, exactly like an explicit
        # claim_size; a claim at the current dims (join storm re-reporting
        # the same size) skips the repaint.
        old_size = state.size

        state =
          state
          |> remember_device(device_id)
          |> become_owner(client, client_ref, rows, cols)

        state = if state.size == old_size, do: state, else: request_repaint_all(state)
        {:reply, :claimed, state}

      true ->
        # Another DEVICE holds the size (live or remembered) — or a legacy
        # client bumped into a live owner: followers render at the owner's
        # size; their viewport never shrinks the shared PTY. Report who
        # owns it so the channel can correct a client whose role went
        # stale.
        {:reply, {:ignored, ownership_snapshot(state)}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Deliberately leaves the holder (and thus the shell) running: surviving
    # BEAM shutdowns and code reloads is the point of the holder split.
    # Explicit kills go through handle_cast(:shutdown) instead.
    if state.socket, do: :gen_tcp.close(state.socket)
    Enum.each(state.waiters, fn _entry -> Dala.Terminal.WaiterLimiter.release(self()) end)
    :ok
  rescue
    _error -> :ok
  end

  @impl true
  def handle_cast({:input, data}, state) do
    _ = Holder.send_input(state.socket, data)
    {:noreply, state}
  end

  def handle_cast({:claim_size, client, client_ref, device_id, rows, cols}, state) do
    # Explicit takeover: last write wins, the previous owner demotes to
    # follower when the size_owner broadcast reaches it. The takeover also
    # rewrites the device memory — the session sticks to this device from
    # now on.
    state = track_client(state, client, client_ref)
    already_owner? = match?({^client, _ref}, state.owner)
    old_size = state.size

    state =
      state
      |> remember_device(device_id)
      |> become_owner(client, client_ref, rows, cols)

    # The PTY was just rewrapped to the new owner's grid: every attached
    # client's buffer — the demoted owner's especially — still shows content
    # wrapped at the old width (the TUI redraws itself on SIGWINCH, but the
    # normal-buffer scrollback does not). Push one fresh snapshot to every
    # client; takeovers are rare, a repaint is cheap. Exception: the owner
    # re-claiming its current dims (repeated refit) rewrapped nothing —
    # skip the repaint storm.
    if already_owner? and state.size == old_size do
      {:noreply, state}
    else
      {:noreply, request_repaint_all(state)}
    end
  end

  def handle_cast({:request_repaint, client}, state) do
    # Every client renders the grid at the PTY's actual size (the owner
    # drives it, followers mirror it), so the repaint's soft wraps must be
    # generated at exactly that width.
    cols = elem(state.size, 1)

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
    # A client disconnected. If it was the LIVE owner, release live
    # ownership WITHOUT resizing — but keep the device memory: the PTY
    # keeps its dimensions and stays reserved for the remembered device
    # until it reconnects or another device explicitly claims.
    state = %{state | clients: Map.delete(state.clients, pid)}

    case state.owner do
      {^pid, _client_ref} ->
        broadcast_size_owner(%{state | owner: nil})
        {:noreply, %{state | owner: nil}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.waiters, fn {_ref, waiter} -> waiter.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {ref, waiter} ->
        release_waiter(waiter, demonitor?: false)
        {:noreply, %{state | waiters: Map.delete(state.waiters, ref)}}
    end
  end

  def handle_info(:force_stop, state) do
    # The holder did not report an exit within the timeout after kill.
    case Dala.Terminal.mark_exited(refresh_session(state), %{exit_code: nil}) do
      {:ok, _session} -> :ok
      {:error, error} -> Logger.warning("could not mark session exited: #{inspect(error)}")
    end

    {:stop, :normal, state}
  end

  def handle_info(:flush_output, state) do
    {:noreply, flush_buffer(%{state | out_timer: nil})}
  end

  def handle_info({:wait_timeout, ref}, state) do
    case Map.pop(state.waiters, ref) do
      {nil, _waiters} ->
        {:noreply, state}

      {waiter, waiters} ->
        GenServer.reply(waiter.from, {:ok, %{reason: "timeout", seq: state.seq}})
        release_waiter(waiter)
        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info({:input_frame, ref}, %{input_active: %{ref: ref} = active} = state) do
    {:noreply, continue_input_job(%{state | input_active: active})}
  end

  def handle_info({:input_frame, _stale_ref}, state), do: {:noreply, state}

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
      case Dala.Terminal.update_cwd(refresh_session(state), %{cwd: cwd}) do
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
        {:noreply, broadcast_agent_event(state, payload)}

      frame_type == Holder.type_repaint() ->
        state = flush_now(state)

        # The socket is FIFO: every output the repaint covers has already
        # been processed, so state.seq is exactly the repaint's watermark.
        case :queue.out(state.pending_repaints) do
          {{:value, :all_clients}, rest} ->
            # Ownership takeover: every attached client replaces its screen
            # with this snapshot (reset replay), not just one requester.
            Enum.each(Map.keys(state.clients), fn client ->
              send(client, {:repaint_reset, payload, state.seq})
            end)

            {:noreply, %{state | pending_repaints: rest}}

          {{:value, client}, rest} ->
            send(client, {:repaint, payload, state.seq})
            {:noreply, %{state | pending_repaints: rest}}

          {:empty, _queue} ->
            {:noreply, state}
        end

      frame_type == Holder.type_text_snapshot() ->
        state = flush_now(state)

        case :queue.out(state.pending_text_snapshots) do
          {{:value, {:caller, from}}, rest} ->
            reply = decode_text_snapshot(payload, state.seq)
            GenServer.reply(from, reply)
            {:noreply, %{state | pending_text_snapshots: rest}}

          {:empty, _queue} ->
            {:noreply, state}
        end

      frame_type == Holder.type_hello() ->
        {shell_pid, holder_proto} =
          case Jason.decode(payload) do
            {:ok, %{"pid" => pid, "proto" => proto}}
            when is_integer(pid) and pid > 0 and is_integer(proto) ->
              {pid, proto}

            {:ok, %{"pid" => pid}} when is_integer(pid) and pid > 0 ->
              {pid, 1}

            _other ->
              {nil, nil}
          end

        # The holder sized the PTY at spawn time; make sure a reattached one
        # matches the size this server last applied.
        {rows, cols} = state.size

        {:noreply,
         apply_size(%{state | shell_pid: shell_pid, holder_proto: holder_proto}, rows, cols,
           force: true
         )}

      frame_type == Holder.type_exit() ->
        <<status::32>> = payload
        exit_with_status(status, state)

      true ->
        {:noreply, state}
    end
  end

  defp exit_with_status(status, state) do
    state = flush_now(state)
    state = wake_waiters(state, "exit", %{reason: "exit", seq: state.seq + 1, exit_code: status})
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
      case Dala.Terminal.mark_exited(refresh_session(state), %{exit_code: status}) do
        {:ok, _session} ->
          :ok

        {:error, error} ->
          Logger.warning("could not mark session #{state.id} exited: #{inspect(error)}")
      end
    end

    {:stop, :normal, state}
  end

  # Metadata updates must run on the COMMITTED row, not the copy this
  # server loaded at spawn: renames/reorders/regroups land over RPC without
  # ever touching this process, so `state.session` goes stale immediately.
  # The broadcast layer re-reads too (Payloads.summary reload) — refreshing
  # here keeps the DB write itself clean if an update action ever grows
  # non-atomic fields, and keeps our in-state copy converging.
  defp refresh_session(state) do
    case Dala.Terminal.get_session(state.session.id) do
      {:ok, fresh} -> fresh
      {:error, _error} -> state.session
    end
  end

  defp current_cwd(nil), do: nil

  defp current_cwd(shell_pid) do
    case File.read_link("/proc/#{shell_pid}/cwd") do
      {:ok, cwd} -> cwd
      {:error, _reason} -> nil
    end
  end

  # Monitor each client the first time we hear from it, so ownership is
  # released when its channel process exits.
  defp track_client(state, client, client_ref) do
    unless Map.has_key?(state.clients, client), do: Process.monitor(client)
    %{state | clients: Map.put(state.clients, client, client_ref)}
  end

  # Makes `client` the size owner, applies its size, and announces the new
  # ownership to every attached client.
  defp become_owner(state, client, client_ref, rows, cols) do
    state = apply_size(%{state | owner: {client, client_ref}}, rows, cols)
    broadcast_size_owner(state)
    state
  end

  # Persists `device_id` as the session's remembered size-owner device (the
  # sticky half of ownership). nil devices (legacy clients, raw callers)
  # leave the memory untouched — nil must NEVER be adopted, so their
  # ownership stays live-only; an unchanged device skips the write.
  defp remember_device(state, nil), do: state
  defp remember_device(%{size_owner_device: device} = state, device), do: state

  defp remember_device(state, device_id) do
    case Dala.Terminal.set_size_owner_device(refresh_session(state), %{
           size_owner_device: device_id
         }) do
      {:ok, session} ->
        %{state | session: session, size_owner_device: device_id}

      {:error, error} ->
        Logger.warning("could not persist size owner device for #{state.id}: #{inspect(error)}")
        # Keep the in-memory ownership consistent even if the write failed.
        # Consequence: the memory is then process-local — it works for every
        # client while THIS server runs, but a server restart falls back to
        # the last persisted device (or none), so another device may adopt
        # then. Acceptable: the write failing at all is already exceptional.
        %{state | size_owner_device: device_id}
    end
  end

  # Ownership + size snapshot: join replies, corrective pushes and
  # `size_owner` broadcasts all carry this one shape.
  defp ownership_snapshot(state) do
    {rows, cols} = state.size

    owner_ref =
      case state.owner do
        {_pid, client_ref} -> client_ref
        nil -> nil
      end

    %{owner: owner_ref, owner_device: state.size_owner_device, rows: rows, cols: cols}
  end

  # Asks the holder for one snapshot to be delivered to EVERY tracked client
  # as a reset replay (see the :all_clients marker in the repaint handler).
  # FIFO ordering guarantees the holder has already applied any resize sent
  # before this request, so the snapshot's wraps match the new grid.
  defp request_repaint_all(state) do
    cols = elem(state.size, 1)

    case Holder.send_repaint_req(state.socket, cols) do
      :ok -> %{state | pending_repaints: :queue.in(:all_clients, state.pending_repaints)}
      {:error, _reason} -> state
    end
  end

  # Sizes the PTY to the owner's viewport. No-op when unchanged (unless
  # forced, e.g. to realign a reattached holder).
  defp apply_size(state, rows, cols, opts \\ []) do
    rows = rows |> max(@min_rows) |> min(@max_rows)
    cols = cols |> max(@min_cols) |> min(@max_cols)

    if {rows, cols} == state.size and not Keyword.get(opts, :force, false) do
      state
    else
      _ = Holder.send_resize(state.socket, rows, cols)
      # Tell every attached client the new PTY size. The owner ignores it
      # (it drives the size); followers render at it and scale to fit.
      DalaWeb.Endpoint.broadcast("terminal:" <> state.id, "resize", %{rows: rows, cols: cols})
      %{state | size: {rows, cols}}
    end
  end

  # Announces who owns the size — the live owner (nil = offline) AND the
  # remembered owner device — plus the current PTY size, so every client
  # can derive its own role from one message.
  defp broadcast_size_owner(state) do
    DalaWeb.Endpoint.broadcast("terminal:" <> state.id, "size_owner", ownership_snapshot(state))
  end

  # Broadcasts an output chunk to connected clients with the next seq.
  # OSC agent notifications from the holder: `title \x1f body`. Structured
  # events (title `warp://cli-agent`, Warp's open protocol) carry a JSON
  # payload from the agent's plugin hooks; OSC 9 ("osc9") and generic OSC 777
  # notifications become plain "notify"/"stop" events. Broadcast on the
  # sessions lobby so the client can notify for background sessions too.
  defp broadcast_agent_event(state, payload) do
    case Dala.Terminal.AgentEvent.parse_agent_event(payload) do
      nil ->
        Logger.debug(
          "agent event unparsed (#{state.id}): #{inspect(payload, printable_limit: 200)}"
        )

        state

      event ->
        seq = state.seq + 1
        event = Map.put(event, :seq, seq)
        Logger.debug("agent event (#{state.id}): #{event.agent}/#{event.event}")
        DalaWeb.Endpoint.broadcast("sessions", "agent_event", Map.put(event, :id, state.id))

        %{
          state
          | seq: seq,
            recent_agent_events: [event | Enum.take(state.recent_agent_events, 31)]
        }
        |> wake_agent_waiters(event)
    end
  end

  defp buffer_output(state, data) do
    if state.out_timer do
      %{state | out_buf: [data | state.out_buf]}
    else
      timer = Process.send_after(self(), :flush_output, @out_batch_ms)
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
    {plain, match_filter_state} = Dala.Terminal.AnsiText.filter(data, state.match_filter_state)

    DalaWeb.Endpoint.broadcast("terminal:" <> state.id, "output", %{
      data: Base.encode64(data),
      seq: seq
    })

    %{
      state
      | seq: seq,
        last_output_seq: seq,
        recent_output: retain_recent_output(state.recent_output, seq, plain),
        match_filter_state: match_filter_state
    }
    |> wake_output_waiters(plain)
  end

  defp start_next_input_job(%{input_active: active} = state) when not is_nil(active), do: state

  defp start_next_input_job(state) do
    case :queue.out(state.input_jobs) do
      {:empty, _queue} ->
        state

      {{:value, {from, frames}}, jobs} ->
        GenServer.reply(from, {:ok, state.seq})

        state
        |> Map.put(:input_jobs, jobs)
        |> Map.put(:input_active, %{ref: make_ref(), frames: frames})
        |> continue_input_job()
    end
  end

  defp continue_input_job(%{input_active: %{frames: []}} = state) do
    state |> Map.put(:input_active, nil) |> start_next_input_job()
  end

  defp continue_input_job(%{input_active: active} = state) do
    [{data, delay} | rest] = active.frames
    _ = Holder.send_input(state.socket, data)
    active = %{active | frames: rest}
    state = %{state | input_active: active}

    cond do
      rest == [] ->
        state |> Map.put(:input_active, nil) |> start_next_input_job()

      delay > 0 ->
        Process.send_after(self(), {:input_frame, active.ref}, delay)
        state

      true ->
        continue_input_job(state)
    end
  end

  defp register_waiter(state, from, after_seq, timeout, events, match) do
    case Dala.Terminal.WaiterLimiter.acquire(self()) do
      :ok ->
        ref = make_ref()
        {caller, _tag} = from

        waiter = %{
          from: from,
          after_seq: after_seq,
          events: events,
          match: match,
          match_buffer: recent_output_since(state, after_seq),
          timer: Process.send_after(self(), {:wait_timeout, ref}, timeout),
          monitor: Process.monitor(caller)
        }

        {:noreply, %{state | waiters: Map.put(state.waiters, ref, waiter)}}

      {:error, :limit} ->
        {:reply, {:error, "too many terminal waiters"}, state}
    end
  end

  defp wake_output_waiters(state, data) do
    waiters =
      Enum.reduce(state.waiters, %{}, fn {ref, waiter}, kept ->
        cond do
          state.last_output_seq <= waiter.after_seq or
              not MapSet.member?(waiter.events, "output") ->
            Map.put(kept, ref, waiter)

          is_binary(waiter.match) ->
            buffer = tail_bytes(waiter.match_buffer <> data, @match_buffer_bytes)

            if :binary.match(buffer, waiter.match) == :nomatch do
              Map.put(kept, ref, %{waiter | match_buffer: buffer})
            else
              reply_waiter(
                waiter,
                {:ok, %{reason: "match", seq: state.seq, match: waiter.match}}
              )

              kept
            end

          true ->
            reply_waiter(waiter, {:ok, %{reason: "output", seq: state.seq}})
            kept
        end
      end)

    %{state | waiters: waiters}
  end

  defp wake_agent_waiters(state, event) do
    kind = agent_wait_kind(event.event)

    {waiters, _replied} =
      Enum.reduce(state.waiters, {%{}, 0}, fn {ref, waiter}, {kept, replied} ->
        accepted? =
          MapSet.member?(waiter.events, kind) or MapSet.member?(waiter.events, event.event)

        if event.seq > waiter.after_seq and accepted? do
          reply_waiter(waiter, {:ok, waiter_agent_result(event)})
          {kept, replied + 1}
        else
          {Map.put(kept, ref, waiter), replied}
        end
      end)

    %{state | waiters: waiters}
  end

  defp wake_waiters(state, _kind, result) do
    Enum.each(state.waiters, fn {_ref, waiter} -> reply_waiter(waiter, {:ok, result}) end)
    %{state | waiters: %{}}
  end

  defp matching_agent_event(events_since, after_seq, accepted_events) do
    Enum.find(events_since, fn event ->
      kind = agent_wait_kind(event.event)

      event.seq > after_seq and
        (MapSet.member?(accepted_events, kind) or
           MapSet.member?(accepted_events, event.event))
    end)
  end

  defp retain_recent_output(recent, seq, data) do
    [{seq, data} | recent]
    |> take_recent_output(@match_buffer_bytes, [])
    |> Enum.reverse()
  end

  defp take_recent_output(_entries, remaining, acc) when remaining <= 0, do: acc
  defp take_recent_output([], _remaining, acc), do: acc

  defp take_recent_output([{seq, data} | rest], remaining, acc) do
    kept = tail_bytes(data, remaining)
    take_recent_output(rest, remaining - byte_size(kept), [{seq, kept} | acc])
  end

  defp recent_output_since(state, after_seq) do
    state.recent_output
    |> Enum.filter(fn {seq, _data} -> seq > after_seq end)
    |> Enum.reverse()
    |> Enum.map_join(fn {_seq, data} -> data end)
  end

  defp recent_output_matches?(state, after_seq, match) do
    :binary.match(recent_output_since(state, after_seq), match) != :nomatch
  end

  defp tail_bytes(data, limit) when byte_size(data) <= limit, do: data
  defp tail_bytes(data, limit), do: binary_part(data, byte_size(data) - limit, limit)

  defp agent_wait_kind("idle_prompt"), do: "idle"
  defp agent_wait_kind("question_asked"), do: "question"
  defp agent_wait_kind("permission_request"), do: "permission"
  defp agent_wait_kind("stop"), do: "stop"
  defp agent_wait_kind("notify"), do: "stop"
  defp agent_wait_kind(other), do: other

  defp waiter_agent_result(event) do
    %{
      reason: "agent",
      seq: event.seq,
      event: event.event,
      agent: event.agent,
      summary: event.summary,
      query: event.query
    }
  end

  defp reply_waiter(waiter, reply) do
    GenServer.reply(waiter.from, reply)
    release_waiter(waiter)
  end

  defp release_waiter(waiter, opts \\ []) do
    Process.cancel_timer(waiter.timer)
    if Keyword.get(opts, :demonitor?, true), do: Process.demonitor(waiter.monitor, [:flush])
    Dala.Terminal.WaiterLimiter.release(self())
  end

  defp decode_text_snapshot(payload, seq) do
    case Jason.decode(payload) do
      {:ok, %{"lines" => lines} = snapshot} when is_list(lines) ->
        {:ok, Map.put(snapshot, "seq", seq)}

      _ ->
        {:error, "terminal holder returned an invalid text snapshot"}
    end
  end
end
