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

  alias Dala.Terminal.{Holder, Pacing}

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
  # MCP wraps this text in JSON and then in an MCP text content string, so a
  # 64 KiB UTF-8 payload keeps the final wire response bounded after escaping.
  @snapshot_max_bytes 64 * 1024
  # The holder applies the same hard limit. Refuse before writing so its reply
  # FIFO and this process's request FIFO can never diverge under overload.
  @max_pending_repaints 64
  @max_pending_text_snapshots 64
  @wait_timeout_max_ms 25_000
  # The holder drops a client whose socket write blocks for two seconds, so a
  # CPU-starved server gets detached with its shell still perfectly alive.
  # Reattaching is the right answer, but a holder that keeps kicking us must
  # not livelock this process — bound consecutive reattaches, and forget the
  # count once a connection has proven itself stable.
  @max_reconnects 5
  @reconnect_reset_ms 10_000
  @waiters_per_session 8
  # Retained window for substring waits. It holds RAW terminal bytes, so a
  # TUI-heavy stream carries less matchable text in it than a plain log does —
  # the alternative, filtering every chunk of every session up front, cost more
  # than the entire rest of the output path.
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
  Report the round trip (ms) this client channel measured against its browser.

  Drives the holder's frame batching window — see `Dala.Terminal.FlowWindow`
  for where the number comes from and the holder's `render_window` for what it
  does with it.
  """
  def report_latency(id, client, rtt_ms) when is_pid(client) and is_integer(rtt_ms) do
    cast_if_alive(id, {:report_latency, client, rtt_ms})
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
  """
  def foreground_app(id) do
    case whereis(id) do
      nil -> {:error, "session is not running"}
      pid -> GenServer.call(pid, :foreground_app, 5_000)
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
      {:ok, socket, _reattached?} ->
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
          holder_proto: nil,
          # Bounded long polls used by MCP. Waiters hold GenServer.from values
          # and are released by output, agent events, exit, timeout or caller
          # death without blocking this process.
          waiters: %{},
          recent_agent_events: [],
          # Bounded raw chunks cover the read -> wait registration race for
          # substring matching without rebuilding the emulator on each chunk.
          # RAW, not filtered: the plain text a substring wait compares against
          # is derived on demand (see plain_text_for_waiters/2).
          recent_output: [],
          # Bytes held in recent_output, so retention never has to measure the
          # list to know when a trim is due.
          recent_output_bytes: 0,
          # Only meaningful while a substring waiter is registered; the filter
          # is not run — and thus not carried — outside those stretches.
          match_filter_state: :text,
          input_jobs: :queue.new(),
          input_active: nil,
          # Monitored client channel pids -> their public client_ref.
          clients: %{},
          # Visible viewers need responsive cwd updates. Warm pooled viewers
          # stay attached but use the much slower background cadence.
          visible_clients: MapSet.new(),
          # Round trip per client channel, as each measures it from its own
          # acknowledgements. The holder is told the SMALLEST across visible
          # viewers: the frame window is a freshness budget and has to suit
          # whoever notices delay first, while bandwidth for slower viewers is
          # already handled per-client by their own flow-control watermark.
          client_rtt: %{},
          reported_rtt: nil,
          cwd_poll_timer: nil,
          # A /proc read can block on a wedged mount, so it stays off this
          # process (see start_cwd_poll/1) — synchronous calls (attach, resize,
          # size_info) must never queue behind the filesystem.
          cwd_poll_task: nil,
          # The LIVE size owner as {pid, client_ref}, or nil. Only the
          # owner's resize reaches the PTY.
          owner: nil,
          # The remembered owner DEVICE (persisted on the session record):
          # ownership is device-sticky. nil until the first device ever
          # attaches/resizes (which adopts the session).
          size_owner_device: session.size_owner_device,
          # Once the stream reports cwd via OSC 7, /proc polling stops: the
          # shell itself is the better source.
          osc7_cwd?: false,
          # Output micro-batching: the first chunk after idle is emitted
          # immediately (keystroke echo pays no extra latency); chunks that
          # land within the 5ms window after it — TUI redraw storms — are
          # coalesced into one broadcast.
          out_buf: [],
          out_timer: nil,
          out_window: Pacing.out_window_floor(),
          out_last_at: System.monotonic_time(:millisecond),
          size: {24, 80},
          # Reattach bookkeeping (see handle_holder_detach/1): when the current
          # connection was established, how many times we have reconnected
          # without a stable stretch in between, and whether the next HELLO
          # owes every client a repair snapshot.
          connected_at: System.monotonic_time(:millisecond),
          reconnects: 0,
          reattach_repair?: false
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

      map_size(state.waiters) >= @waiters_per_session ->
        {:reply, {:error, "too many terminal waiters for this session"}, state}

      true ->
        # One pass over the retained window answers both questions: did the
        # needle already arrive, and what context does a fresh waiter start
        # from. Filtering it twice cost ~0.2-0.9ms per wait.
        history = if is_binary(match), do: recent_plain_output_since(state, after_seq), else: ""

        if is_binary(match) and MapSet.member?(events, "output") and
             :binary.match(history, match) != :nomatch do
          {:reply, {:ok, %{reason: "match", seq: state.seq, match: match}}, state}
        else
          register_waiter(state, from, after_seq, timeout, events, match, history)
        end
    end
  end

  def handle_call({:send_sequence, frames}, from, state) do
    jobs = :queue.in({from, frames}, state.input_jobs)
    {:noreply, start_next_input_job(%{state | input_jobs: jobs})}
  end

  @impl true
  def handle_call(:foreground_app, _from, state) do
    cmdline = Dala.Terminal.Foreground.cmdline(state.shell_pid)

    {:reply,
     {:ok, %{app: Dala.Terminal.AgentEvent.classify_app(cmdline), cmdline: cmdline || ""}}, state}
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

  def handle_cast({:set_visibility, client, client_ref, visible}, state) do
    had_visible? = MapSet.size(state.visible_clients) > 0
    state = track_client(state, client, client_ref)

    visible_clients =
      if visible,
        do: MapSet.put(state.visible_clients, client),
        else: MapSet.delete(state.visible_clients, client)

    state = push_latency(%{state | visible_clients: visible_clients})
    has_visible? = MapSet.size(visible_clients) > 0

    state =
      cond do
        not had_visible? and has_visible? -> schedule_cwd_poll(state, 0)
        had_visible? and not has_visible? -> schedule_cwd_poll(state, @cwd_poll_hidden_ms)
        true -> state
      end

    {:noreply, state}
  end

  def handle_cast({:report_latency, client, rtt_ms}, state) do
    state = %{state | client_rtt: Map.put(state.client_rtt, client, rtt_ms)}
    {:noreply, push_latency(state)}
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

  def handle_info({:tcp_closed, socket}, state), do: holder_socket_lost(socket, state)

  def handle_info({:tcp_error, socket, _reason}, state), do: holder_socket_lost(socket, state)

  # The delivery window closed after its bounded burst. Re-open it immediately:
  # the backlog belongs in the holder's bounded ring, but only while this
  # socket keeps asking for more.
  def handle_info({:tcp_passive, socket}, %{socket: socket} = state) do
    _ = Holder.rearm(socket)
    {:noreply, state}
  end

  # A superseded connection. Reattaching makes the holder hang up the socket we
  # left behind, so its trailing frames and passive notice arrive AFTER the live
  # one is in place; neither may disturb it.
  def handle_info({:tcp, _stale_socket, _payload}, state), do: {:noreply, state}

  def handle_info({:tcp_passive, _stale_socket}, state), do: {:noreply, state}

  # CWD poll workers are monitored separately from channel and waiter
  # monitors. This clause must precede the generic DOWN handlers below.
  def handle_info(
        {:DOWN, monitor, :process, pid, reason},
        %{cwd_poll_task: %{monitor: monitor, pid: pid, started_at: started_at}} = state
      ) do
    # A worker that exits before returning a result (for example, an
    # exception in process discovery) must not stop the terminal server.
    if reason not in [:normal, :shutdown],
      do: Logger.debug("cwd poll task exited for #{state.id}: #{inspect(reason)}")

    state = %{state | cwd_poll_task: nil}
    {:noreply, schedule_cwd_poll(state, cwd_poll_delay(state, started_at))}
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
        client_rtt: Map.delete(state.client_rtt, pid),
        visible_clients: MapSet.delete(state.visible_clients, pid)
    }

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
    coalesced? = state.out_buf != []
    state = flush_buffer(%{state | out_timer: nil})
    {:noreply, %{state | out_window: Pacing.next_out_window(state.out_window, coalesced?)}}
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

  def handle_info({:poll_cwd, ref}, %{cwd_poll_timer: {ref, _timer}} = state) do
    state = %{state | cwd_poll_timer: nil}
    {:noreply, start_cwd_poll(state)}
  end

  def handle_info({:poll_cwd, _stale_ref}, state), do: {:noreply, state}

  # A worker sends its result before the monitor DOWN signal. The ref guard is
  # important: a canceled/old query must never overwrite a cwd reported by
  # OSC 7 in the meantime.
  def handle_info(
        {task_ref, {:cwd_poll_result, cwd}},
        %{cwd_poll_task: %{ref: task_ref, monitor: monitor, started_at: started_at}} = state
      ) do
    Process.demonitor(monitor, [:flush])
    delay = cwd_poll_delay(state, started_at)
    state = Map.put(state, :cwd_poll_task, nil)

    # A shell that reports OSC 7 is authoritative about its own cwd; the poll
    # only covers shells that do not (and its answer is stale for those that
    # started reporting while the query was in flight).
    state = if cwd && not state.osc7_cwd?, do: apply_cwd(state, cwd), else: state

    {:noreply, schedule_cwd_poll(state, delay)}
  end

  def handle_info({task_ref, {:cwd_poll_result, _stale_result}}, state)
      when is_reference(task_ref),
      do: {:noreply, state}

  # Reading another process's cwd goes through the filesystem, which can block
  # on a wedged mount — keep it off this GenServer so attach, resize and
  # size_info stay responsive. At most one query runs at a time, and it captures
  # only the values it needs: never hand the mutable state to the worker.
  # A shell that reports OSC 7 has retired the poll for good: rescheduling only
  # happens off a poll result, so returning here ends the loop instead of
  # spawning a worker every two seconds to compute nil.
  defp start_cwd_poll(%{osc7_cwd?: true} = state), do: state

  defp start_cwd_poll(state) do
    if is_nil(Map.get(state, :cwd_poll_task)) do
      shell_pid = state.shell_pid
      owner = self()
      task_ref = make_ref()

      {pid, monitor} =
        spawn_monitor(fn ->
          send(owner, {task_ref, {:cwd_poll_result, current_cwd(shell_pid)}})
        end)

      Map.put(state, :cwd_poll_task, %{
        pid: pid,
        ref: task_ref,
        monitor: monitor,
        started_at: System.monotonic_time(:millisecond)
      })
    else
      state
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
        # OSC 7 from the stream: the shell tells us where it is, which retires
        # /proc polling for this session.
        {:noreply, apply_cwd(%{state | osc7_cwd?: true}, payload)}

      frame_type == Holder.type_agent() ->
        {:noreply, broadcast_agent_event(state, payload)}

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

        state =
          apply_size(%{state | shell_pid: shell_pid, holder_proto: holder_proto}, rows, cols,
            force: true
          )

        # A reattach after an unexpected detach: the holder cleared its transit
        # queue, so the bytes it dropped in between exist only in its emulator.
        # Now that the resize is ahead of it on the FIFO, repair every client.
        if state.reattach_repair? do
          {:noreply, request_repaint_all(%{state | reattach_repair?: false})}
        else
          {:noreply, state}
        end

      frame_type == Holder.type_exit() ->
        <<status::32>> = payload
        exit_with_status(status, state)

      true ->
        {:noreply, state}
    end
  end

  # The connection to the holder is gone. That is NOT proof the shell died: the
  # holder hangs up on a client whose write blocks for two seconds, which is
  # what a saturated machine does to this process — and it also kicks us when a
  # newer client connects. The exit-status file is the only authoritative death
  # certificate; while the holder is still listening, reattach to it instead of
  # burying a live shell as "exited" (which leaves the UI with a dead terminal
  # and a no-op kill button until the session is rejoined).
  defp holder_socket_lost(socket, state) do
    _ = :gen_tcp.close(socket)

    if socket == state.socket,
      do: handle_holder_detach(%{state | socket: nil}),
      else: {:noreply, state}
  end

  defp handle_holder_detach(state) do
    case Holder.take_exit_status(state.id) do
      status when is_integer(status) -> exit_with_status(status, state)
      nil -> reattach_or_exit(state)
    end
  end

  defp reattach_or_exit(state) do
    now = System.monotonic_time(:millisecond)

    reconnects =
      if now - state.connected_at >= @reconnect_reset_ms, do: 0, else: state.reconnects

    if reconnects >= @max_reconnects do
      Logger.warning(
        "holder for #{state.id} hung up #{reconnects} times in a row; marking exited"
      )

      exit_with_status(nil, state)
    else
      # connect/1 answers "is the holder still listening?" on its own: no socket
      # file means {:error, :enoent}, which is the give-up path either way.
      case Holder.connect(state.id) do
        {:ok, socket} ->
          Logger.info("reattached to the holder for #{state.id} after an unexpected detach")

          state =
            %{
              state
              | socket: socket,
                connected_at: now,
                reconnects: reconnects + 1,
                # The repair waits for HELLO so the holder applies this
                # server's size before rendering the snapshot.
                reattach_repair?: true
            }
            |> flush_now()
            |> settle_pending_holder_requests()

          {:noreply, state}

        {:error, _reason} ->
          exit_with_status(nil, state)
      end
    end
  end

  # Requests queued against the connection that just died. The holder answers
  # over the socket's FIFO, so those slots can never be filled — settle every
  # requester with the same sentinel used for an unreachable holder rather than
  # leaving channels covered and MCP callers blocked until they time out.
  defp settle_pending_holder_requests(state) do
    Enum.each(:queue.to_list(state.pending_repaints), fn
      {:all_clients, _history_budget} ->
        :ok

      {client, _history_budget, request_ref} ->
        send_repaint(client, "", state.seq, false, request_ref)

      # Pre-ref queue entry (hot code upgrade), same as in the repaint handler.
      {client, _history_budget} ->
        send_repaint(client, "", state.seq, false, nil)
    end)

    Enum.each(:queue.to_list(state.pending_text_snapshots), fn {:caller, from} ->
      GenServer.reply(from, {:error, "terminal holder is unavailable"})
    end)

    %{
      state
      | pending_repaints: :queue.new(),
        pending_text_snapshots: :queue.new(),
        deferred_all_client_repaint: false
    }
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

          # A parent being deleted closes its attached shells while their own
          # shells are exiting, so both paths race for the same row. Whoever
          # loses finds it already gone, which is the desired end state.
          {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{} | _]}} ->
            :ok

          {:error, error} ->
            Logger.warning("could not destroy session #{session.id}: #{inspect(error)}")
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

  # The cadence this session wants, backed off by what the poll that just
  # finished actually cost.
  defp cwd_poll_delay(state, started_at) do
    duration = System.monotonic_time(:millisecond) - started_at
    Pacing.next_cwd_poll_interval(cwd_poll_interval(state), duration)
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

  # Monitor each client the first time we hear from it, so ownership is
  # released when its channel process exits.
  @doc false
  # The holder's frame window follows the most latency-sensitive VISIBLE
  # viewer. Reported only when it moves enough to matter — a window that
  # jitters by a millisecond changes nothing a person can see and would put a
  # socket write on every acknowledgement.
  def effective_rtt(client_rtt, visible_clients) do
    client_rtt
    |> Enum.filter(fn {client, _rtt} -> MapSet.member?(visible_clients, client) end)
    |> Enum.map(fn {_client, rtt} -> rtt end)
    |> case do
      [] -> nil
      values -> Enum.min(values)
    end
  end

  @doc false
  def rtt_worth_reporting?(nil, _previous), do: false
  def rtt_worth_reporting?(_current, nil), do: true

  def rtt_worth_reporting?(current, previous),
    do: abs(current - previous) >= max(div(previous, 5), 2)

  defp push_latency(state) do
    current = effective_rtt(state.client_rtt, state.visible_clients)

    if rtt_worth_reporting?(current, state.reported_rtt) do
      if state.socket, do: Holder.send_latency(state.socket, current)
      %{state | reported_rtt: current}
    else
      state
    end
  end

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
      gap = System.monotonic_time(:millisecond) - state.out_last_at
      window = Pacing.out_window_after_gap(state.out_window, gap)
      timer = Process.send_after(self(), :flush_output, window)
      %{emit(state, data) | out_timer: timer, out_window: window}
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
    {plain, match_filter_state} = plain_text_for_waiters(state, data)

    DalaWeb.Endpoint.broadcast("terminal:" <> state.id, "output", %{
      data: Base.encode64(data),
      seq: seq
    })

    %{
      state
      | seq: seq,
        last_output_seq: seq,
        match_filter_state: match_filter_state,
        # Every path that emits goes through here, so this is the one place the
        # idle gap can be measured from.
        out_last_at: System.monotonic_time(:millisecond)
    }
    |> retain_recent_output(seq, data)
    |> wake_output_waiters(plain)
  end

  # Plain text is needed ONLY to feed MCP substring waits. Extracting it from
  # every chunk cost more than the rest of the output path combined (base64,
  # JSON and websocket compression together), all of it inside this process —
  # the one that also has to answer keystrokes, resize and repaint. So it is
  # spent only while a substring waiter is actually registered; `recent_output`
  # retains the RAW bytes and is filtered on demand when a wait arrives.
  #
  # The filter state is not carried across a stretch with no waiter (there was
  # nothing to carry it through), so a sequence straddling the moment a waiter
  # registers may contribute a few of its parameter bytes to that waiter's
  # match text. Substring waits tolerate that; paying for every byte of every
  # session to close it does not pay for itself.
  defp plain_text_for_waiters(state, data) do
    if match_waiters?(state) do
      Dala.Terminal.AnsiText.filter(data, state.match_filter_state)
    else
      {"", :text}
    end
  end

  defp match_waiters?(state) do
    Enum.any?(state.waiters, fn {_ref, waiter} -> is_binary(waiter.match) end)
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

  defp register_waiter(state, from, after_seq, timeout, events, match, history) do
    case Dala.Terminal.WaiterLimiter.acquire(self()) do
      :ok ->
        ref = make_ref()
        {caller, _tag} = from

        waiter = %{
          from: from,
          after_seq: after_seq,
          events: events,
          match: match,
          match_buffer: match_context(history, match),
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
            buffer = waiter.match_buffer <> data

            if :binary.match(buffer, waiter.match) == :nomatch do
              Map.put(kept, ref, %{waiter | match_buffer: match_context(buffer, waiter.match)})
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

  # Newest-first, so retaining is a cons. Trimming walks the whole window, so it
  # runs only once the window has grown to twice its bound rather than on every
  # chunk: a shell dribbling 64-byte writes keeps thousands of entries alive, and
  # rebuilding that list per chunk cost ~21us of the session process every time.
  defp retain_recent_output(state, seq, data) do
    recent = [{seq, data} | state.recent_output]
    bytes = state.recent_output_bytes + byte_size(data)

    if bytes > 2 * @match_buffer_bytes do
      kept = take_recent_output(recent, @match_buffer_bytes, [])
      %{state | recent_output: Enum.reverse(kept), recent_output_bytes: retained_bytes(kept)}
    else
      %{state | recent_output: recent, recent_output_bytes: bytes}
    end
  end

  defp take_recent_output(_entries, remaining, acc) when remaining <= 0, do: acc
  defp take_recent_output([], _remaining, acc), do: acc

  defp take_recent_output([{seq, data} | rest], remaining, acc) do
    kept = tail_bytes(data, remaining)
    take_recent_output(rest, remaining - byte_size(kept), [{seq, kept} | acc])
  end

  defp retained_bytes(entries) do
    Enum.reduce(entries, 0, fn {_seq, data}, total -> total + byte_size(data) end)
  end

  # The retained window holds raw terminal bytes; a substring wait compares
  # against plain text, so the filter runs here — once per wait call instead of
  # once per output chunk.
  defp recent_plain_output_since(state, after_seq) do
    {plain, _state} =
      state
      |> recent_output_since(after_seq)
      |> Dala.Terminal.AnsiText.filter()

    plain
  end

  defp recent_output_since(state, after_seq) do
    state.recent_output
    |> Enum.filter(fn {seq, _data} -> seq > after_seq end)
    |> Enum.reverse()
    |> Enum.map_join(fn {_seq, data} -> data end)
  end

  # Everything a waiter still needs from what it has already seen: a needle can
  # only straddle a chunk boundary by up to its own length minus one byte. The
  # history before registration was already searched, so carrying the whole
  # 128 KiB window forward would copy it on every chunk for nothing.
  defp match_context(_buffer, nil), do: ""
  defp match_context(buffer, match), do: tail_bytes(buffer, max(byte_size(match) - 1, 0))

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
