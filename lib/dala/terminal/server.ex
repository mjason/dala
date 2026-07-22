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

  @cwd_poll_visible_ms 2_000
  @cwd_poll_hidden_ms 30_000
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
  # The holder applies the same hard limit. Refuse before writing so its reply
  # FIFO and this process's request FIFO can never diverge under overload.
  @max_pending_repaints 64
  @max_pending_text_snapshots 64
  @max_pending_foregrounds 64
  @foreground_timeout_ms 4_000
  @process_request_proto 6
  @pty_query_proto 7
  # A healthy holder writes this local-socket ACK after draining at most its
  # bounded 1 MiB transit queue. Its own socket write timeout is two seconds,
  # so waiting longer means the ownership state can no longer be trusted.
  @query_owner_ack_timeout_ms 2_500
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

  @doc "Track whether a channel is actively visible to its user."
  def set_visibility(id, client, client_ref, visible)
      when is_pid(client) and is_boolean(visible) do
    cast_if_alive(id, {:set_visibility, client, client_ref, visible})
  end

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

  @doc "Initial viewport report; resizes without an extra repaint fan-out."
  def attach(id, client, client_ref, device_id, rows, cols) when is_pid(client) do
    case whereis(id) do
      nil -> :ok
      pid -> GenServer.call(pid, {:attach, client, client_ref, device_id, rows, cols})
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

  @doc "Terminal capabilities negotiated with the attached holder."
  def capabilities(id) do
    case whereis(id) do
      nil -> terminal_capabilities(nil, false)
      pid -> GenServer.call(pid, :capabilities)
    end
  end

  @doc "Register a joined terminal channel before it begins receiving output."
  def register_query_client(id, client, client_ref, supported)
      when is_pid(client) and is_boolean(supported) do
    case whereis(id) do
      nil ->
        {:ok, terminal_capabilities(nil, false)}

      pid ->
        {:ok, GenServer.call(pid, {:register_query_client, client, client_ref, supported}, 5_000)}
    end
  catch
    :exit, _reason -> {:error, :query_owner_unavailable}
  end

  @doc "Confirm that this browser has installed its query-suppression handlers."
  def query_client_ready(id, client), do: cast_if_alive(id, {:query_client_ready, client})

  @doc "Allow query negotiation after a full BEAM boot reattaches this holder."
  def allow_query_owner(id), do: cast_if_alive(id, :allow_query_owner)

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
  `{:repaint, data, seq, history_loaded, request_ref}` message. `seq` is the
  seq of the last output the repaint covers, so the client can deduplicate the
  live stream against it. The ref is echoed only for targeted requests and
  lets a channel accept a matching late response after timeout while rejecting
  one superseded by a newer request.
  """
  def request_repaint(id, client, opts \\ []) when is_pid(client) do
    history_budget =
      if Keyword.get(opts, :history, :full) == :screen,
        do: 0,
        else: Holder.repaint_history_budget()

    case whereis(id) do
      nil ->
        {:error, :not_running}

      pid ->
        GenServer.cast(pid, {
          :request_repaint,
          client,
          history_budget,
          Keyword.get(opts, :ref)
        })

        :ok
    end
  end

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
      [{pid, _value}] -> if(Process.alive?(pid), do: pid, else: nil)
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
    _ = Holder.kill(id)
    :ok
  end

  ## Server

  @impl true
  def init(session) do
    id = to_string(session.id)
    shell = Dala.Terminal.Shell.normalize_executable(session.shell)
    shell_options = Dala.Terminal.Shell.spawn_options(shell)

    opts = [
      shell: shell,
      args: shell_options[:args],
      cwd: session.cwd,
      env:
        [
          {"TERM", "xterm-256color"},
          {"COLORTERM", "truecolor"},
          # Advertise Warp's open cli-agent notification protocol: the agent
          # plugins (claude-code-warp, opencode-warp, …) emit OSC 777 events
          # only when these are present.
          {"WARP_CLI_AGENT_PROTOCOL_VERSION", "1"},
          {"WARP_CLIENT_VERSION", "dala"}
        ] ++ shell_options[:env],
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
          # Resize/takeover repairs coalesce while the bounded holder FIFO is
          # saturated, then append as soon as any response opens a slot.
          deferred_all_client_repaint: false,
          # Machine snapshots use the holder's FIFO response queue.
          pending_text_snapshots: :queue.new(),
          pending_foregrounds: %{},
          foreground_request_seq: 0,
          holder_proto: nil,
          # Query ownership is an opt-in protocol-7 handshake. The holder is
          # always disabled on connection; every joined channel (including
          # pre-attach legacy clients) must declare support and then confirm
          # its xterm suppression handlers are ready before it can be enabled.
          query_clients: %{},
          query_owner_phase: :disabled,
          query_owner_enabled?: false,
          query_owner_command: nil,
          query_owner_recovery_attempt: 0,
          # A reattached holder may still have browser channels from the
          # previous Server process. Their capabilities are unknowable here,
          # so keep xterm authoritative for this Server lifetime. Freshly
          # spawned sessions can negotiate normally.
          query_owner_negotiable?: not reattached?,
          query_register_waiters: [],
          # An ACK timeout replaces only the BEAM/holder control connection;
          # the PTY and shell stay alive. HELLO then requests one authoritative
          # repaint to cover output that landed during the handoff.
          recovering_holder?: false,
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
          # Visible viewers need responsive cwd updates. Warm pooled viewers
          # stay attached but use the much slower background cadence.
          visible_clients: MapSet.new(),
          cwd_poll_timer: nil,
          # CWD discovery may invoke a multiplexer CLI with a hard 1.5s
          # timeout. Keep that work out of this GenServer so synchronous
          # calls (attach, resize and size_info) remain responsive.
          cwd_poll_task: nil,
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
          # While a mux is active its top-level OSC 7 is only a candidate.
          # Retain it so a poll that observes mux exit can apply it at once.
          osc7_cwd_candidate: nil,
          # zellij/tmux client detected under the shell — cwd then comes
          # from the multiplexer itself (focused pane), not OSC 7 or /proc.
          mux: nil,
          # A failed mux CLI query is not proof that the mux exited. Keep OSC
          # 7 as a candidate until the next process-discovery pass confirms it.
          mux_recheck?: false,
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
    {:noreply, schedule_cwd_poll(state, cwd_poll_interval(state))}
  end

  @impl true
  def handle_call(:viewport, _from, state) do
    {:reply, state.size, state}
  end

  @impl true
  def handle_call(:size_info, _from, state) do
    {:reply, ownership_snapshot(state), state}
  end

  def handle_call(:capabilities, _from, state) do
    {:reply,
     terminal_capabilities(
       state.holder_proto,
       state.query_owner_enabled?,
       state.query_owner_negotiable?
     ), state}
  end

  def handle_call(
        {:register_query_client, client, client_ref, supported},
        from,
        state
      ) do
    # Registration runs inside Channel.join/3, before the socket starts
    # receiving output. A newly joined client is deliberately not ready yet:
    # if the holder currently owns queries, first wait for its disable ACK so
    # the join reply can safely tell the browser to arm xterm.
    state =
      state
      |> track_client(client, client_ref)
      |> put_query_client(client, supported, false)
      |> reconcile_query_owner()

    if query_owner_safely_disabled?(state) do
      {:reply, terminal_capabilities(state.holder_proto, false, state.query_owner_negotiable?),
       state}
    else
      waiter = %{from: from, client: client}
      {:noreply, %{state | query_register_waiters: [waiter | state.query_register_waiters]}}
    end
  end

  def handle_call(:current_seq, _from, state), do: {:reply, {:ok, state.seq}, state}

  def handle_call({:text_snapshot, _lines, _max_bytes}, _from, %{holder_proto: proto} = state)
      when is_integer(proto) and proto < 3 do
    {:reply, {:error, "restart this session to enable plain-text terminal snapshots"}, state}
  end

  def handle_call({:text_snapshot, lines, max_bytes}, from, state) do
    if text_snapshot_queue_full?(state) do
      {:reply, {:error, "too many pending terminal snapshot requests"}, state}
    else
      case Holder.send_text_snapshot_req(state.socket, lines, max_bytes) do
        :ok ->
          pending = :queue.in({:caller, from}, state.pending_text_snapshots)
          {:noreply, %{state | pending_text_snapshots: pending}}

        {:error, _reason} ->
          {:reply, {:error, "terminal holder is unavailable"}, state}
      end
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
  def handle_call(:foreground_app, from, state) do
    if windows?() do
      cond do
        not (is_integer(state.holder_proto) and state.holder_proto >= @process_request_proto) ->
          {:reply, {:ok, unknown_foreground()}, state}

        map_size(state.pending_foregrounds) >= @max_pending_foregrounds ->
          {:reply, {:error, "too many pending foreground process requests"}, state}

        true ->
          request_id = rem(state.foreground_request_seq, 0xFFFFFFFFFFFFFFFF) + 1

          case Holder.send_processes_req(state.socket, request_id) do
            :ok ->
              timer =
                Process.send_after(
                  self(),
                  {:foreground_timeout, request_id},
                  @foreground_timeout_ms
                )

              pending =
                Map.put(state.pending_foregrounds, request_id, %{from: from, timer: timer})

              {:noreply,
               %{
                 state
                 | pending_foregrounds: pending,
                   foreground_request_seq: request_id
               }}

            {:error, _reason} ->
              {:reply, {:ok, unknown_foreground()}, state}
          end
      end
    else
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
       {:ok, %{app: Dala.Terminal.AgentEvent.classify_app(cmdline), cmdline: cmdline || ""}},
       state}
    end
  end

  @impl true
  def handle_call(:kick_viewers, _from, state) do
    {:reply, Dala.Terminal.Viewers.kick_others(state.shell_pid), state}
  end

  @impl true
  def handle_call({:resize, client, client_ref, device_id, rows, cols}, _from, state) do
    handle_resize(client, client_ref, device_id, rows, cols, false, state)
  end

  def handle_call({:attach, client, client_ref, device_id, rows, cols}, _from, state) do
    handle_resize(client, client_ref, device_id, rows, cols, true, state)
  end

  defp handle_resize(client, client_ref, device_id, rows, cols, initial_attach?, state) do
    had_other_clients? = Enum.any?(state.clients, fn {pid, _ref} -> pid != client end)
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

        state =
          if state.size == old_size or (initial_attach? and not had_other_clients?),
            do: state,
            else: request_repaint_all(state)

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
    cancel_cwd_poll(state)
    cancel_query_owner_command(state)
    if state.socket, do: :gen_tcp.close(state.socket)

    Enum.each(state.pending_foregrounds, fn {_id, request} ->
      Process.cancel_timer(request.timer)
      GenServer.reply(request.from, {:ok, unknown_foreground()})
    end)

    Enum.each(state.query_register_waiters, fn waiter ->
      if Process.alive?(waiter.client) do
        GenServer.reply(waiter.from, terminal_capabilities(nil, false))
      end
    end)

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

  def handle_cast({:query_client_ready, client}, state) do
    state =
      case Map.get(state.query_clients, client) do
        %{supported?: true} = capability ->
          query_clients =
            Map.put(state.query_clients, client, %{capability | ready?: true})

          reconcile_query_owner(%{state | query_clients: query_clients})

        _legacy_or_unknown ->
          state
      end

    {:noreply, state}
  end

  def handle_cast(:allow_query_owner, state) do
    # Terminal.Boot is the only caller: after a full BEAM restart no old
    # Phoenix channels can survive. If a new channel raced application boot,
    # stay conservative and leave xterm authoritative for this Server.
    state =
      if map_size(state.query_clients) == 0 do
        state
        |> Map.put(:query_owner_negotiable?, true)
        |> broadcast_terminal_capabilities()
        |> reconcile_query_owner()
      else
        state
      end

    {:noreply, state}
  end

  def handle_cast({:set_visibility, client, client_ref, visible}, state) do
    had_visible? = MapSet.size(state.visible_clients) > 0
    state = track_client(state, client, client_ref)

    visible_clients =
      if visible,
        do: MapSet.put(state.visible_clients, client),
        else: MapSet.delete(state.visible_clients, client)

    state = %{state | visible_clients: visible_clients}
    has_visible? = MapSet.size(visible_clients) > 0

    state =
      cond do
        not had_visible? and has_visible? -> schedule_cwd_poll(state, 0)
        had_visible? and not has_visible? -> schedule_cwd_poll(state, @cwd_poll_hidden_ms)
        true -> state
      end

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

  # Keep the three-tuple form for callers compiled against the pre-ref API.
  def handle_cast({:request_repaint, client, history_budget}, state),
    do: handle_cast({:request_repaint, client, history_budget, nil}, state)

  def handle_cast({:request_repaint, client, history_budget, request_ref}, state) do
    # Every client renders the grid at the PTY's actual size (the owner
    # drives it, followers mirror it), so the repaint's soft wraps must be
    # generated at exactly that width.
    cols = elem(state.size, 1)

    if repaint_queue_full?(state) do
      # The request never reached the holder. Settle it with the same sentinel
      # used for an unavailable holder so a Channel does not wait until its
      # timeout, and echo the ref so only this generation accepts it.
      send_repaint(client, "", state.seq, false, request_ref)
      {:noreply, state}
    else
      case Holder.send_repaint_req(state.socket, cols, history_budget) do
        :ok ->
          pending = :queue.in({client, history_budget, request_ref}, state.pending_repaints)
          {:noreply, %{state | pending_repaints: pending}}

        {:error, _reason} ->
          # Holder unreachable — answer empty so the client is not left covered.
          # Empty data never contains history; reporting true would prevent the
          # browser from retrying a full-history request.
          send_repaint(client, "", state.seq, false, request_ref)

          {:noreply, state}
      end
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

  # A replaced control connection can still leave close/error/data messages
  # in this process's mailbox. They belong to an older holder generation and
  # must not stop (or feed) the recovered server.
  def handle_info({:tcp, _stale_socket, _frame}, state), do: {:noreply, state}
  def handle_info({:tcp_closed, _stale_socket}, state), do: {:noreply, state}
  def handle_info({:tcp_error, _stale_socket, _reason}, state), do: {:noreply, state}

  # CWD poll workers are monitored separately from channel and waiter
  # monitors. This clause must precede the generic DOWN handlers below.
  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{cwd_poll_task: %{monitor: monitor, pid: pid}} = state
      ) do
    # A worker that exits before returning a result (for example, an
    # exception in process discovery) must not stop the terminal server.
    if reason not in [:normal, :shutdown],
      do: Logger.debug("cwd poll task exited for #{state.id}: #{inspect(reason)}")

    state = %{state | cwd_poll_task: nil}
    {:noreply, schedule_cwd_poll(state, cwd_poll_interval(state))}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state)
      when is_map_key(state.clients, pid) do
    # A client disconnected. If it was the LIVE owner, release live
    # ownership WITHOUT resizing — but keep the device memory: the PTY
    # keeps its dimensions and stays reserved for the remembered device
    # until it reconnects or another device explicitly claims.
    was_visible? = MapSet.member?(state.visible_clients, pid)

    state = %{
      state
      | clients: Map.delete(state.clients, pid),
        visible_clients: MapSet.delete(state.visible_clients, pid),
        query_clients: Map.delete(state.query_clients, pid),
        query_register_waiters: Enum.reject(state.query_register_waiters, &(&1.client == pid))
    }

    state = reconcile_query_owner(state)

    state =
      if was_visible? and MapSet.size(state.visible_clients) == 0,
        do: schedule_cwd_poll(state, @cwd_poll_hidden_ms),
        else: state

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

  def handle_info({:foreground_timeout, request_id}, state) do
    case Map.pop(state.pending_foregrounds, request_id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:ok, unknown_foreground()})
        {:noreply, %{state | pending_foregrounds: pending}}
    end
  end

  def handle_info({:query_owner_ack_timeout, ref}, state) do
    case Map.get(state, :query_owner_command) do
      %{ref: ^ref, enabled: enabled} ->
        attempt = Map.get(state, :query_owner_recovery_attempt, 0) + 1

        if attempt == 1 or rem(attempt, 12) == 0 do
          Logger.warning(
            "terminal #{state.id} query-owner #{if(enabled, do: "enable", else: "disable")} " <>
              "ACK timed out; replacing the holder control connection " <>
              "(attempt #{attempt})"
          )
        end

        state =
          state
          |> Map.put(:query_owner_command, nil)
          |> Map.put(:query_owner_recovery_attempt, attempt)

        {:noreply, recover_holder_connection(state, enabled)}

      _stale_generation ->
        {:noreply, state}
    end
  end

  def handle_info({:input_frame, ref}, %{input_active: %{ref: ref} = active} = state) do
    {:noreply, continue_input_job(%{state | input_active: active})}
  end

  def handle_info({:input_frame, _stale_ref}, state), do: {:noreply, state}

  def handle_info({:poll_cwd, ref}, %{cwd_poll_timer: {ref, _timer}} = state) do
    state = %{state | cwd_poll_timer: nil}
    {:noreply, start_cwd_poll(state)}
  end

  def handle_info({:poll_cwd, _stale_ref}, state), do: {:noreply, state}

  # A worker sends its result before the monitor DOWN signal. The ref guard is
  # important: a canceled/old query must never overwrite a newer mux detection
  # result (or a cwd reported by OSC 7 in the meantime).
  def handle_info(
        {task_ref,
         {:cwd_poll_result, %{status: status, mux: mux, cwd: cwd, osc7_cwd?: queried_osc7?}}},
        %{cwd_poll_task: %{ref: task_ref, monitor: monitor}} = state
      ) do
    Process.demonitor(monitor, [:flush])

    state =
      state
      |> Map.put(:cwd_poll_task, nil)
      |> Map.put(:mux, mux)
      |> Map.put(:mux_recheck?, status == :mux_query_failed)

    # A mux result remains authoritative because panes do not forward OSC 7.
    # Only process discovery can confirm that the mux disappeared; a CLI
    # timeout/query failure merely forces discovery again on the next tick.
    state =
      cond do
        status == :mux && mux != nil && cwd ->
          apply_cwd(state, cwd)

        status == :confirmed_no_mux &&
            is_binary(Map.get(state, :osc7_cwd_candidate)) ->
          apply_cwd(state, state.osc7_cwd_candidate)

        status == :confirmed_no_mux && cwd &&
            not (state.osc7_cwd? && not queried_osc7?) ->
          apply_cwd(state, cwd)

        true ->
          state
      end

    {:noreply, schedule_cwd_poll(state, cwd_poll_interval(state))}
  end

  def handle_info({task_ref, {:cwd_poll_result, _stale_result}}, state)
      when is_reference(task_ref),
      do: {:noreply, state}

  # zellij/tmux never forward their panes' OSC 7 and their shells live under
  # a detached server invisible to /proc — while a multiplexer client runs in
  # this session, ask the multiplexer itself for the focused pane's cwd.
  # Detection reads the shared short-lived process snapshot while no mux is
  # known, so all sessions amortize one `ps` scan; a failing mux query falls
  # back to detection on the next tick.
  # Start at most one query at a time. A query captures only the small set of
  # values it needs; never hand the mutable GenServer state to the task.
  defp start_cwd_poll(state) do
    if is_nil(Map.get(state, :cwd_poll_task)) do
      query = %{shell_pid: state.shell_pid, mux: state.mux, osc7_cwd?: state.osc7_cwd?}
      owner = self()
      task_ref = make_ref()

      {pid, monitor} =
        spawn_monitor(fn ->
          send(owner, {task_ref, {:cwd_poll_result, poll_cwd_once(query)}})
        end)

      Map.put(state, :cwd_poll_task, %{pid: pid, ref: task_ref, monitor: monitor})
    else
      state
    end
  end

  # Runs entirely in the task process. The returned map is deliberately
  # detached from the server state so a late result can be rejected by ref.
  defp poll_cwd_once(%{mux: nil, shell_pid: shell_pid, osc7_cwd?: osc7_cwd?}) do
    case Dala.Terminal.Viewers.find_mux(shell_pid) do
      nil ->
        %{
          status: :confirmed_no_mux,
          mux: nil,
          cwd: if(osc7_cwd?, do: nil, else: current_cwd(shell_pid)),
          osc7_cwd?: osc7_cwd?
        }

      mux ->
        case Dala.Terminal.MuxCwd.cwd(mux) do
          {:ok, cwd} ->
            %{status: :mux, mux: mux, cwd: cwd, osc7_cwd?: osc7_cwd?}

          :error ->
            %{status: :mux_query_failed, mux: nil, cwd: nil, osc7_cwd?: osc7_cwd?}
        end
    end
  end

  defp poll_cwd_once(%{mux: mux, osc7_cwd?: osc7_cwd?}) do
    case Dala.Terminal.MuxCwd.cwd(mux) do
      {:ok, cwd} -> %{status: :mux, mux: mux, cwd: cwd, osc7_cwd?: osc7_cwd?}
      :error -> %{status: :mux_query_failed, mux: nil, cwd: nil, osc7_cwd?: osc7_cwd?}
    end
  end

  defp cancel_cwd_poll(state) do
    if cwd_poll_timer = Map.get(state, :cwd_poll_timer) do
      {_message_ref, timer} = cwd_poll_timer
      Process.cancel_timer(timer)
    end

    case Map.get(state, :cwd_poll_task) do
      %{pid: pid, monitor: monitor} ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)

      nil ->
        :ok
    end

    :ok
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
        # report is only a candidate. If an in-flight query discovers that the
        # mux exited, the result handler promotes this value immediately.
        state = Map.merge(state, %{osc7_cwd?: true, osc7_cwd_candidate: payload})

        if state.mux || Map.get(state, :mux_recheck?, false) do
          {:noreply, state}
        else
          {:noreply, apply_cwd(state, payload)}
        end

      frame_type == Holder.type_agent() ->
        {:noreply, broadcast_agent_event(state, payload)}

      frame_type == Holder.type_processes() ->
        case payload do
          <<request_id::64, encoded::binary>> ->
            case Map.pop(state.pending_foregrounds, request_id) do
              {%{from: from, timer: timer}, pending} ->
                Process.cancel_timer(timer)

                result =
                  case Jason.decode(encoded) do
                    {:ok, processes} when is_list(processes) ->
                      Dala.Terminal.AgentEvent.foreground_from_processes(processes)

                    _other ->
                      unknown_foreground()
                  end

                GenServer.reply(from, {:ok, result})
                {:noreply, %{state | pending_foregrounds: pending}}

              {nil, _pending} ->
                {:noreply, state}
            end

          _invalid ->
            {:noreply, state}
        end

      frame_type == Holder.type_query_owner() ->
        case payload do
          <<enabled>> when enabled in [0, 1] ->
            # The holder's ACK is an output barrier. Preserve that FIFO at the
            # Phoenix layer too: micro-batched bytes before it must reach xterm
            # before browsers switch which side answers terminal queries.
            state = flush_now(state)
            {:noreply, handle_query_owner_ack(state, enabled == 1)}

          _invalid ->
            {:noreply, state}
        end

      frame_type == Holder.type_repaint() ->
        state = flush_now(state)

        # The socket is FIFO: every output the repaint covers has already
        # been processed, so state.seq is exactly the repaint's watermark.
        case :queue.out(state.pending_repaints) do
          {{:value, {:all_clients, history_budget}}, rest} ->
            # Ownership takeover: every attached client replaces its screen
            # with this snapshot (reset replay), not just one requester.
            Enum.each(Map.keys(state.clients), fn client ->
              send(client, {
                :repaint_reset,
                payload,
                state.seq,
                history_loaded?(state, history_budget)
              })
            end)

            state = %{state | pending_repaints: rest}
            {:noreply, maybe_request_deferred_all_client_repaint(state)}

          {{:value, {client, history_budget, request_ref}}, rest} ->
            send_repaint(
              client,
              payload,
              state.seq,
              history_loaded?(state, history_budget),
              request_ref
            )

            state = %{state | pending_repaints: rest}
            {:noreply, maybe_request_deferred_all_client_repaint(state)}

          # A queue entry created before the ref extension may still be
          # present during a hot code upgrade. Treat it as an untagged reply;
          # current channels will reject it when no matching request exists.
          {{:value, {client, history_budget}}, rest} ->
            send_repaint(client, payload, state.seq, history_loaded?(state, history_budget), nil)

            state = %{state | pending_repaints: rest}
            {:noreply, maybe_request_deferred_all_client_repaint(state)}

          {:empty, _queue} ->
            {:noreply, maybe_request_deferred_all_client_repaint(state)}
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

        recovering? = Map.get(state, :recovering_holder?, false)

        state =
          state
          |> cancel_query_owner_command()
          |> Map.merge(%{
            shell_pid: shell_pid,
            holder_proto: holder_proto,
            query_owner_phase: :disabled,
            query_owner_enabled?: false,
            recovering_holder?: false
          })
          |> apply_size(rows, cols, force: true)
          |> broadcast_terminal_capabilities()
          |> reset_holder_query_owner()

        state = if recovering?, do: request_repaint_all(state), else: state

        {:noreply, state}

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

  defp cwd_poll_interval(state) do
    if MapSet.size(state.visible_clients) > 0,
      do: @cwd_poll_visible_ms,
      else: @cwd_poll_hidden_ms
  end

  defp schedule_cwd_poll(state, delay) do
    if state.cwd_poll_timer do
      {_message_ref, timer} = state.cwd_poll_timer
      Process.cancel_timer(timer)
    end

    message_ref = make_ref()
    timer = Process.send_after(self(), {:poll_cwd, message_ref}, delay)
    %{state | cwd_poll_timer: {message_ref, timer}}
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  defp unknown_foreground, do: %{app: "unknown", cmdline: ""}

  # Monitor each client the first time we hear from it, so ownership is
  # released when its channel process exits.
  defp track_client(state, client, client_ref) do
    unless Map.has_key?(state.clients, client), do: Process.monitor(client)

    state = %{
      state
      | clients: Map.put(state.clients, client, client_ref),
        query_clients:
          Map.put_new(state.query_clients, client, %{supported?: false, ready?: false})
    }

    reconcile_query_owner(state)
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

  defp terminal_capabilities(proto, enabled, negotiable? \\ true) do
    supported = negotiable? and is_integer(proto) and proto >= @pty_query_proto

    %{
      holder_query_owner: supported and enabled,
      holder_query_owner_supported: supported
    }
  end

  defp put_query_client(state, client, supported, ready) do
    capability = %{supported?: supported, ready?: supported and ready}
    %{state | query_clients: Map.put(state.query_clients, client, capability)}
  end

  defp query_owner_desired?(state) do
    state.query_owner_negotiable? and is_integer(state.holder_proto) and
      state.holder_proto >= @pty_query_proto and
      state.socket != nil and
      (map_size(state.query_clients) == 0 or
         Enum.all?(state.query_clients, fn {_pid, capability} ->
           capability.supported? and capability.ready?
         end))
  end

  defp query_owner_safely_disabled?(state) do
    not is_nil(state.holder_proto) and state.query_owner_phase == :disabled and
      not state.query_owner_enabled?
  end

  defp reconcile_query_owner(state) do
    desired? = query_owner_desired?(state)

    case {state.query_owner_phase, desired?} do
      {:disabled, true} -> send_query_owner_command(state, true)
      {:enabled, false} -> send_query_owner_command(state, false)
      # A target change while an ACK is in flight is serialized: once that
      # ACK arrives, handle_query_owner_ack/2 immediately sends the inverse
      # command without ever advertising the transient state to browsers.
      _unchanged_or_in_flight -> state
    end
  end

  defp send_query_owner_command(state, enabled) do
    case Holder.send_query_owner(state.socket, enabled) do
      :ok ->
        state
        |> cancel_query_owner_command()
        |> Map.put(:query_owner_recovery_attempt, 0)
        |> Map.put(:query_owner_phase, if(enabled, do: :enabling, else: :disabling))
        |> schedule_query_owner_timeout(enabled)

      {:error, reason} ->
        Logger.warning(
          "terminal #{state.id} could not send query-owner command: #{inspect(reason)}; " <>
            "replacing the holder control connection"
        )

        state
        |> cancel_query_owner_command()
        |> Map.put(:query_owner_phase, if(enabled, do: :enabling, else: :disabling))
        |> Map.put(:query_owner_recovery_attempt, 1)
        |> recover_holder_connection(enabled)
    end
  end

  defp reset_holder_query_owner(state) do
    if is_integer(state.holder_proto) and state.holder_proto >= @pty_query_proto do
      send_query_owner_command(state, false)
    else
      state
      |> Map.merge(%{query_owner_phase: :disabled, query_owner_enabled?: false})
      |> reply_query_register_waiters()
    end
  end

  defp handle_query_owner_ack(state, enabled) do
    state =
      state
      |> cancel_query_owner_command()
      |> Map.put(:query_owner_recovery_attempt, 0)

    state = %{
      state
      | query_owner_phase: if(enabled, do: :enabled, else: :disabled),
        query_owner_enabled?: enabled
    }

    cond do
      enabled and not query_owner_desired?(state) ->
        # A legacy/unready client joined while ENABLE was in flight. Disable
        # again without broadcasting the transient enabled state.
        send_query_owner_command(state, false)

      enabled ->
        broadcast_terminal_capabilities(state)

      true ->
        state
        |> broadcast_terminal_capabilities()
        |> reply_query_register_waiters()
        |> reconcile_query_owner()
    end
  end

  defp reply_query_register_waiters(state) do
    capabilities =
      terminal_capabilities(state.holder_proto, false, state.query_owner_negotiable?)

    Enum.each(state.query_register_waiters, fn waiter ->
      if Process.alive?(waiter.client), do: GenServer.reply(waiter.from, capabilities)
    end)

    %{state | query_register_waiters: []}
  end

  defp broadcast_terminal_capabilities(state) do
    DalaWeb.Endpoint.broadcast(
      "terminal:" <> state.id,
      "terminal_capabilities",
      terminal_capabilities(
        state.holder_proto,
        state.query_owner_enabled?,
        state.query_owner_negotiable?
      )
    )

    state
  end

  defp cancel_query_owner_command(state) do
    case Map.get(state, :query_owner_command) do
      %{timer: timer} -> Process.cancel_timer(timer)
      _none -> :ok
    end

    Map.put(state, :query_owner_command, nil)
  end

  defp schedule_query_owner_timeout(state, enabled) do
    ref = make_ref()

    timer =
      Process.send_after(
        self(),
        {:query_owner_ack_timeout, ref},
        @query_owner_ack_timeout_ms
      )

    Map.put(state, :query_owner_command, %{enabled: enabled, ref: ref, timer: timer})
  end

  # Reconnecting installs a fresh holder client generation. The holder does
  # that under its ownership lock and starts the new generation with query
  # handling disabled, giving us a known browser-owned baseline without
  # killing the shell. Requests queued on the old generation are settled
  # before their holder-side FIFOs are discarded, then HELLO rebuilds state
  # and requests a reset repaint for every attached channel.
  defp recover_holder_connection(state, enabled) do
    old_socket = state.socket

    case Holder.connect(state.id) do
      {:ok, socket} ->
        state =
          state
          |> flush_now()
          |> settle_abandoned_holder_requests()
          |> Map.merge(%{
            socket: socket,
            holder_proto: nil,
            query_owner_phase: :disabled,
            query_owner_enabled?: false,
            query_owner_recovery_attempt: 0,
            recovering_holder?: true
          })
          |> schedule_query_owner_timeout(false)

        if old_socket && old_socket != socket, do: :gen_tcp.close(old_socket)
        state

      {:error, reason} ->
        # Keep the original connection in place: it may still deliver the
        # late ACK or a close notification. Never claim browser ownership
        # without an ACK; retain the normal five-second join bound and keep a
        # generation-tagged recovery attempt alive instead.
        if Map.get(state, :query_owner_recovery_attempt, 0) == 1 do
          Logger.error(
            "terminal #{state.id} could not replace holder connection after query-owner timeout: " <>
              inspect(reason)
          )
        end

        schedule_query_owner_timeout(state, enabled)
    end
  end

  defp settle_abandoned_holder_requests(state) do
    Enum.each(:queue.to_list(state.pending_repaints), fn
      {client, _history_budget, request_ref} when is_pid(client) ->
        send_repaint(client, "", state.seq, false, request_ref)

      {client, _history_budget} when is_pid(client) ->
        send_repaint(client, "", state.seq, false, nil)

      {:all_clients, _history_budget} ->
        :ok
    end)

    Enum.each(:queue.to_list(state.pending_text_snapshots), fn
      {:caller, from} -> GenServer.reply(from, {:error, "terminal holder reconnected"})
    end)

    Enum.each(state.pending_foregrounds, fn {_request_id, request} ->
      Process.cancel_timer(request.timer)
      GenServer.reply(request.from, {:ok, unknown_foreground()})
    end)

    %{
      state
      | pending_repaints: :queue.new(),
        deferred_all_client_repaint: false,
        pending_text_snapshots: :queue.new(),
        pending_foregrounds: %{}
    }
  end

  # Asks the holder for one snapshot to be delivered to EVERY tracked client
  # as a reset replay (see the :all_clients marker in the repaint handler).
  # FIFO ordering guarantees the holder has already applied any resize sent
  # before this request, so the snapshot's wraps match the new grid.
  defp request_repaint_all(state) do
    if repaint_queue_full?(state) do
      # Preserve one repair intent. Sending now would exceed the holder's same
      # hard limit and silently shift the ref-less response FIFO; the first
      # completed request below appends one repair for the latest size.
      Map.put(state, :deferred_all_client_repaint, true)
    else
      cols = elem(state.size, 1)
      history_budget = Holder.repaint_history_budget()

      case Holder.send_repaint_req(state.socket, cols, history_budget) do
        :ok ->
          state
          |> Map.put(:deferred_all_client_repaint, false)
          |> Map.put(
            :pending_repaints,
            :queue.in({:all_clients, history_budget}, state.pending_repaints)
          )

        {:error, _reason} ->
          Map.put(state, :deferred_all_client_repaint, true)
      end
    end
  end

  defp maybe_request_deferred_all_client_repaint(state) do
    if Map.get(state, :deferred_all_client_repaint, false) and not repaint_queue_full?(state),
      do: request_repaint_all(state),
      else: state
  end

  defp repaint_queue_full?(state),
    do: :queue.len(state.pending_repaints) >= @max_pending_repaints

  defp text_snapshot_queue_full?(state),
    do: :queue.len(state.pending_text_snapshots) >= @max_pending_text_snapshots

  # Protocol v5 is the first holder that honors the extended repaint budget.
  # An old holder ignores the extra four bytes and returns its normal full
  # snapshot, so report that conservative truth to the browser.
  defp history_loaded?(%{holder_proto: proto}, history_budget) do
    history_budget > 0 or not (is_integer(proto) and proto >= 5)
  end

  # Preserve the pre-ref four-tuple for direct/legacy callers. Channel
  # requests carry a reference and get the tagged form used for stale-reply
  # suppression.
  defp send_repaint(client, payload, seq, history_loaded, nil),
    do: send(client, {:repaint, payload, seq, history_loaded})

  defp send_repaint(client, payload, seq, history_loaded, request_ref),
    do: send(client, {:repaint, payload, seq, history_loaded, request_ref})

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
