defmodule DalaWeb.TerminalChannel do
  @moduledoc """
  Per-session terminal channel.

  On join, the client receives a fast synthesized repaint of the current
  screen and terminal modes rendered by the holder-side emulator. Scrollback
  is fetched only when requested. For sessions that are no longer running,
  the holder's final screen file is served instead. Live output arrives as
  `output` broadcasts from `Dala.Terminal.Server`; overlap with the repaint is
  deduplicated client-side via `seq`.
  """

  use Phoenix.Channel
  use AshTypescript.TypedChannel

  alias Dala.Terminal.Holder

  # Output flow control (per client): once the client starts acking parsed
  # bytes, sent-minus-acked is capped by a watermark. Past it the channel
  # DROPS chunks; when the acks drain it requests one repaint snapshot and
  # resumes — the backlog ahead of a keystroke echo stays bounded on slow
  # links (mosh's state-sync idea). Clients that never ack (older bundles)
  # get the full stream, exactly as before.
  # Capability transitions share the intercepted output path so Phoenix cannot
  # fastlane them past an earlier output frame. The browser's xterm-write
  # barrier relies on this transport order when query ownership changes.
  intercept ["output", "exit", "terminal_capabilities"]

  # Alt screen (TUIs — no scrollback to lose): skip aggressively.
  @high_water_alt 128 * 1024
  # Normal buffer: skipping costs scrollback lines, so only cap pathological
  # floods.
  @high_water_normal 768 * 1024
  @low_water 32 * 1024
  # Acks lost / client wedged: force the repaint rather than staying dark.
  @flow_deadline_ms 4_000
  # Client joined but never attached with its viewport: replay anyway.
  @repaint_timeout_ms 4_000
  # A timeout fallback may reveal the last settled frame, but it is not an
  # emulator baseline. Keep deltas gated and retry slowly until the holder can
  # provide an authoritative snapshot.
  @repaint_retry_ms 1_000

  # Keep pushed frames comfortably small; base64 inflates by 4/3.
  @replay_batch_bytes 192 * 1024
  # Viewport clamp, mirrored by Dala.Terminal.Server (its apply_size is the
  # authoritative choke point) and by the holder itself.
  @min_rows 2
  @max_rows 500
  @min_cols 2
  @max_cols 1000

  typed_channel do
    topic "terminal:*"

    resource Dala.Terminal.Session do
      publish :output
      publish :replay
      publish :exit
      publish :cwd
    end
  end

  @impl true
  def join("terminal:" <> session_id, payload, socket) do
    case Dala.Terminal.get_session(session_id) do
      {:ok, session} ->
        session = reconcile_status(session)

        client_id = Ash.UUID.generate()

        # Size ownership is DEVICE-sticky (see Dala.Terminal.Server.resize/6):
        # the client sends its stable device id in the join params. Clients
        # that don't (legacy bundles) join with a NIL device: the server
        # then falls back to the old per-connection model for them — they
        # can hold LIVE ownership while connected, but nothing is ever
        # remembered (a per-connection id persisted as the device would
        # ghost-lock the session for every future client).
        device_id =
          case payload do
            %{"device_id" => device} when is_binary(device) and device != "" -> device
            _other -> nil
          end

        query_owner_supported? = payload["terminal_query_owner"] == true

        # Register during join, before this channel can receive PTY output.
        # Protocol-7 holders default to browser ownership. If another viewer
        # had enabled holder ownership, Server waits for its disable ACK here
        # so a legacy browser never enters with both responders active.
        case Dala.Terminal.Server.register_query_client(
               session_id,
               self(),
               client_id,
               query_owner_supported?
             ) do
          {:ok, capabilities} ->
            complete_join(
              session,
              client_id,
              device_id,
              query_owner_supported?,
              capabilities,
              socket
            )

          {:error, _reason} ->
            {:error, %{reason: "query_owner_unavailable"}}
        end

      {:error, _error} ->
        {:error, %{reason: "not_found"}}
    end
  end

  defp complete_join(
         session,
         client_id,
         device_id,
         query_owner_supported?,
         capabilities,
         socket
       ) do
    session_id = to_string(session.id)

    # The reply tells this client who holds the size — the live owner and the
    # remembered owner device — plus its own client_id so it can recognize
    # itself in `size_owner` broadcasts. Exited sessions report no live owner.
    %{owner: owner, owner_device: owner_device, rows: rows, cols: cols} =
      Dala.Terminal.Server.size_info(session_id) ||
        %{owner: nil, owner_device: nil, rows: 24, cols: 80}

    socket =
      socket
      |> assign(:session_id, session.id)
      |> assign(:client_id, client_id)
      |> assign(:device_id, device_id)
      |> assign(:query_owner_supported, query_owner_supported?)
      |> assign(:visible, true)
      |> assign(:initial_repaint_timed_out, false)
      |> assign(:fc, %{
        enabled: false,
        alt: false,
        sent: 0,
        acked: 0,
        skipping: false,
        repaint_requested: false,
        pending_history: nil,
        queued_history: nil,
        # A holder repaint is asynchronous. The ref/generation pair lets us
        # settle a lost request without allowing its late response to clear a
        # newer request's state.
        repaint_generation: 0,
        repaint_ref: nil,
        repaint_timer: nil,
        repaint_retry_timer: nil,
        repaint_timed_out: false,
        repaint_fallback_sent: false
      })

    send(self(), :after_join)

    {:ok,
     %{
       status: session.status,
       cwd: session.cwd,
       rows: rows,
       cols: cols,
       owner: owner,
       owner_device: owner_device,
       client_id: client_id,
       platform: platform_name(),
       holder_query_owner: capabilities.holder_query_owner,
       holder_query_owner_supported: capabilities.holder_query_owner_supported
     }, socket}
  end

  # A brutally-killed Terminal.Server (code-reload purge, VM crash mid-callback)
  # never runs terminate/2, so its session stays "running" with no process
  # behind it — the UI then shows a dead terminal with no restart overlay and
  # "kill" is a no-op. Reconcile on join, like Dala.Terminal.Boot does at
  # startup: reattach when the detached holder still runs the shell, mark the
  # session exited otherwise so the restart path works again.
  defp reconcile_status(%{status: :running} = session) do
    id = to_string(session.id)

    cond do
      Dala.Terminal.Server.alive?(id) ->
        session

      Dala.Terminal.Holder.exists?(id) ->
        _ = Dala.Terminal.Server.ensure_started(session)
        session

      true ->
        exit_code = Dala.Terminal.Holder.take_exit_status(id)

        case Dala.Terminal.mark_exited(session, %{exit_code: exit_code}) do
          {:ok, reconciled} -> reconciled
          {:error, _error} -> session
        end
    end
  end

  defp reconcile_status(session), do: session

  defp platform_name do
    case :os.type() do
      {:win32, _} -> "windows"
      {:unix, :darwin} -> "macos"
      _ -> "linux"
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    id = socket.assigns.session_id

    # Join-reply → topic-subscribe gap: the reply's ownership snapshot was
    # read BEFORE this channel subscribed to the topic, so a `size_owner`
    # broadcast landing in between is lost to this client. Re-read now that
    # the subscription exists and push it, so the client's role is correct
    # even when ownership changed in the gap.
    case Dala.Terminal.Server.size_info(id) do
      %{owner: _owner} = snapshot ->
        push(socket, "size_owner", snapshot)

      nil ->
        :ok
    end

    if Dala.Terminal.Server.alive?(id) do
      # The repaint is deferred until the client's `attach` reports its true
      # viewport — sizing first lets the emulator reflow, so soft wraps match
      # the client's width. The timer covers clients that never attach.
      # This is only the join-without-attach fallback. Attach requests use a
      # generation-bound timer below so a stale timeout cannot settle a later
      # repaint.
      Process.send_after(self(), :initial_repaint_timeout, @repaint_timeout_ms)
      {:noreply, assign(socket, :replayed, false)}
    else
      # Not running: serve the final screen the holder left behind.
      {:noreply, push_replay(socket, Holder.read_final(id), 0)}
    end
  end

  def handle_info({:repaint, data, seq, history_loaded}, socket) do
    handle_repaint(socket, data, seq, history_loaded, nil)
  end

  def handle_info({:repaint, data, seq, history_loaded, repaint_ref}, socket) do
    handle_repaint(socket, data, seq, history_loaded, repaint_ref)
  end

  def handle_info({:repaint_reset, data, seq, history_loaded}, socket) do
    # Size-ownership takeover rewrapped the PTY: replace this client's screen
    # with the fresh snapshot unless a newer targeted request is pending. The
    # holder and Server are FIFO, so an all-client response observed behind an
    # active targeted barrier is necessarily older. Even pushing its done frame
    # would let the browser uncover and send input before the repair arrives.
    fc = socket.assigns.fc

    if repaint_pending?(fc, socket) do
      {:noreply, socket}
    else
      fc = clear_repaint(fc, reset?: true, bytes: byte_size(data))

      {:noreply,
       socket
       |> push_replay(data, seq, true, history_loaded)
       |> assign(:fc, fc)
       |> assign(:repaint_requested, false)
       |> assign(:initial_repaint_timed_out, false)}
    end
  end

  def handle_info(:flow_repaint_deadline, socket) do
    {:noreply, maybe_flow_repaint(socket, force: true)}
  end

  def handle_info({:repaint_timeout, generation, repaint_ref}, socket) do
    fc = socket.assigns.fc

    if Map.get(fc, :repaint_generation, 0) == generation and
         Map.get(fc, :repaint_ref) == repaint_ref and
         not Map.get(fc, :repaint_timed_out, false) and
         repaint_pending?(fc, socket) do
      if Map.get(fc, :queued_history) == :full do
        # The user's scroll/search request is stronger than the timed-out
        # viewport catch-up. Replace the old generation with a full repaint
        # and retain the visual/output barrier; revealing an empty fallback
        # here would consume the browser's pending history intent.
        {:noreply, request_queued_history(socket)}
      else
        # Reveal the last settled pixels, but do not resume deltas: the old
        # emulator is missing every byte discarded behind this snapshot. A
        # matching late response remains authoritative until the retry rotates
        # the generation/ref.
        {:noreply, defer_repaint(socket, keep_ref?: true)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:repaint_retry, generation}, socket) do
    fc = socket.assigns.fc

    if Map.get(fc, :repaint_generation, 0) == generation and
         Map.get(fc, :repaint_timed_out, false) and
         Map.get(fc, :pending_history) in [:screen, :full] do
      history = Map.get(fc, :queued_history) || Map.get(fc, :pending_history)

      socket =
        assign(
          socket,
          :fc,
          Map.merge(fc, %{queued_history: nil, repaint_retry_timer: nil})
        )

      {:noreply,
       start_repaint(socket, history,
         preserve_barrier?: true,
         retry?: true,
         skip?: true
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:initial_repaint_timeout, socket) do
    if socket.assigns[:replayed] or repaint_pending?(socket.assigns.fc, socket) do
      {:noreply, socket}
    else
      # No viewport arrived, so use the PTY's current size. An empty replay
      # would let subsequent deltas build on an emulator with no baseline.
      {:noreply, request_repaint_once(socket, :screen, initial?: true)}
    end
  end

  defp handle_repaint(socket, data, seq, history_loaded, repaint_ref) do
    fc = socket.assigns.fc

    # A timed-out request may still be sitting in the server/holder FIFO. A
    # response with a ref that is no longer pending belongs to that old
    # generation and must not reset the current stream ledger.
    if not repaint_response_matches?(fc, socket, repaint_ref) do
      {:noreply, socket}
    else
      requested? =
        Map.get(fc, :repaint_ref) != nil or Map.get(fc, :repaint_requested, false) or
          Map.get(socket.assigns, :repaint_requested, false)

      cond do
        requested? and data == "" and history_loaded == false ->
          # An empty, history-less response is the Server's holder-unavailable
          # sentinel. Keep the last usable frame and its seq baseline while a
          # generation-bound retry obtains the missing authoritative state.
          {:noreply, defer_repaint(socket, keep_ref?: false)}

        requested? and Map.get(fc, :queued_history) == :full and not history_loaded ->
          # A viewport request was already in flight when the browser asked
          # for scrollback. Do not reveal the incomplete snapshot: retain the
          # existing cover/skip barrier and atomically replace this generation
          # with a full-history request.
          {:noreply, request_queued_history(socket)}

        requested? ->
          # Requested snapshot — flow-control skip or a user-initiated reset
          # (handle_in "repaint"); either way the client resets and continues
          # from seq. Initial attach is the one pending request that should
          # keep reset=false; its top-level flag distinguishes it below.
          # An initial request is normally non-reset because the browser's join
          # gate supplies that edge. Once an empty fallback has consumed the
          # gate, the later authority must carry reset on the wire so seq and
          # emulator baselines are replaced together.
          reset? = fc.repaint_requested or Map.get(fc, :repaint_fallback_sent, false)
          socket = push_replay(socket, data, seq, reset?, history_loaded)
          # sent counts the snapshot too — the client acks those bytes as it
          # parses them, keeping the cumulative ledger consistent.
          fc = clear_repaint(fc, reset?: true, bytes: byte_size(data))

          {:noreply,
           socket
           |> assign(:fc, fc)
           |> assign(:repaint_requested, false)
           |> assign(:initial_repaint_timed_out, false)}

        socket.assigns[:replayed] ->
          {:noreply, socket}

        true ->
          socket = push_replay(socket, data, seq, false, history_loaded)
          {:noreply, assign(socket, :repaint_requested, false)}
      end
    end
  end

  @impl true
  def handle_out("output", %{data: encoded} = payload, socket) do
    fc = socket.assigns.fc
    size = decoded_size(encoded)

    cond do
      # A catch-up/flow snapshot is the authoritative screen baseline. Drop
      # every incremental frame until it arrives, including legacy clients
      # that have not enabled byte acknowledgements.
      fc.skipping ->
        {:noreply, socket}

      not fc.enabled ->
        push(socket, "output", payload)
        # The first browser ack enables flow control and may cover output sent
        # before that ack. Charge these bytes now so activation cannot begin
        # with acked > sent and a negative backlog.
        {:noreply, assign(socket, :fc, %{fc | sent: fc.sent + size})}

      fc.sent - fc.acked + size > high_water(fc) ->
        Process.send_after(self(), :flow_repaint_deadline, @flow_deadline_ms)
        {:noreply, assign(socket, :fc, %{fc | skipping: true})}

      true ->
        push(socket, "output", payload)
        {:noreply, assign(socket, :fc, %{fc | sent: fc.sent + size})}
    end
  end

  def handle_out("terminal_capabilities", payload, socket) do
    push(socket, "terminal_capabilities", payload)
    {:noreply, socket}
  end

  def handle_out("exit", payload, socket) do
    push(socket, "exit", payload)

    {:noreply,
     socket
     |> assign(:fc, clear_repaint(socket.assigns.fc, reset?: true))
     |> assign(:repaint_requested, false)}
  end

  @impl true
  def handle_in("attach", %{"rows" => rows, "cols" => cols}, socket)
      when is_integer(rows) and is_integer(cols) do
    {rows, cols} = clamp_dims(rows, cols)

    # Order matters: the resize reaches the holder (reflow) before the
    # repaint request on the same FIFO socket. (If another client owns the
    # size it is ignored — followers attach at the PTY's size anyway.)
    resize_with_correction(socket, rows, cols, initial_attach?: true)

    fc = socket.assigns.fc

    socket =
      cond do
        repaint_pending?(fc, socket) ->
          socket

        socket.assigns[:initial_repaint_timed_out] ->
          # The join-without-attach fallback revealed an empty frame. A late
          # viewport report must still fetch an authoritative reset snapshot;
          # otherwise `replayed=true` would leave the session blank forever.
          request_repaint_once(socket, :screen)

        not socket.assigns[:replayed] ->
          request_repaint_once(socket, :screen, initial?: true)

        true ->
          socket
      end

    {:noreply, socket}
  end

  def handle_in("input", %{"data" => data}, socket) when is_binary(data) do
    Dala.Terminal.Server.input(socket.assigns.session_id, data)
    {:noreply, socket}
  end

  def handle_in("query_owner_ready", _payload, socket) do
    if socket.assigns.query_owner_supported do
      Dala.Terminal.Server.query_client_ready(socket.assigns.session_id, self())
    end

    {:noreply, socket}
  end

  def handle_in("resize", %{"rows" => rows, "cols" => cols}, socket)
      when is_integer(rows) and is_integer(cols) do
    {rows, cols} = clamp_dims(rows, cols)
    # `self()` is this channel process — one per connected client. Ownership
    # is device-sticky: the remembered device's resize always applies (and
    # the first device ever adopts an unowned session); any other device's
    # resize is dropped by the server and answered with a corrective
    # `size_owner` push (see resize_with_correction/3).
    resize_with_correction(socket, rows, cols)

    {:noreply, socket}
  end

  # Explicit size takeover (the follower banner's button): become the live
  # owner, make this DEVICE the remembered owner, and resize the PTY to this
  # client's viewport. The server broadcasts `size_owner` so the previous
  # owner demotes itself.
  def handle_in("claim_size", %{"rows" => rows, "cols" => cols}, socket)
      when is_integer(rows) and is_integer(cols) do
    {rows, cols} = clamp_dims(rows, cols)

    Dala.Terminal.Server.claim_size(
      socket.assigns.session_id,
      self(),
      socket.assigns.client_id,
      socket.assigns.device_id,
      rows,
      cols
    )

    {:noreply, socket}
  end

  # User-initiated repaint (the toolbar Reset button): fetch one holder
  # snapshot and deliver it to THIS client as a reset replay (clear +
  # replace). A `\f` keystroke only redraws a bare shell prompt; inside
  # zellij/claude-code/any TUI it is swallowed (or typed as input), so the
  # holder snapshot is the only reliable full-screen repaint.
  def handle_in("repaint", _payload, socket) do
    id = socket.assigns.session_id
    fc = socket.assigns.fc

    cond do
      not Dala.Terminal.Server.alive?(id) ->
        # Session no longer running: re-serve the final screen the holder
        # left behind (the client just blanked itself locally).
        fc = clear_repaint(fc, reset?: true)

        {:noreply,
         socket
         |> push_replay(Holder.read_final(id), 0, true)
         |> assign(:fc, fc)
         |> assign(:repaint_requested, false)}

      repaint_pending?(fc, socket) ->
        # A snapshot is already in flight for this client (the flow-control
        # skip path) — it lands as a reset replay, which is exactly what
        # this reset wants. Requesting another would double-repaint.
        {:noreply, socket}

      true ->
        # Mark it in the flow ledger so a concurrent skip drain reuses this
        # snapshot instead of requesting its own (see maybe_flow_repaint).
        {:noreply, request_repaint_once(socket, :full)}
    end
  end

  # Cold attach intentionally omits scrollback. The browser asks for the
  # bounded full snapshot only when the user scrolls upward or searches.
  def handle_in("load_history", _payload, socket) do
    {:noreply, request_repaint_once(socket, :full, upgrade?: true)}
  end

  # A pooled hidden terminal that dropped its bounded local delta needs only
  # the latest viewport when revealed, not another scrollback transfer.
  def handle_in("catch_up", _payload, socket) do
    {:noreply, request_repaint_once(socket, :screen, skip?: true)}
  end

  def handle_in("visibility", %{"visible" => visible}, socket) when is_boolean(visible) do
    Dala.Terminal.Server.set_visibility(
      socket.assigns.session_id,
      self(),
      socket.assigns.client_id,
      visible
    )

    {:noreply, assign(socket, :visible, visible)}
  end

  def handle_in("ack", %{"bytes" => bytes} = payload, socket) when is_integer(bytes) do
    fc = socket.assigns.fc

    # A reconnect can deliver a stale queued ack from the prior Channel
    # generation. Never let it create negative backlog in this fresh ledger.
    acked = min(fc.acked + max(bytes, 0), fc.sent)

    fc = %{
      fc
      | enabled: true,
        acked: acked,
        alt: payload["alt"] == true
    }

    {:noreply, maybe_flow_repaint(assign(socket, :fc, fc))}
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # Cheap defense at the channel layer; Server.apply_size is the
  # authoritative choke point with the same bounds.
  defp clamp_dims(rows, cols) do
    {rows |> max(@min_rows) |> min(@max_rows), cols |> max(@min_cols) |> min(@max_cols)}
  end

  # Reports this client's viewport to the session server. When the server
  # IGNORES it (another device holds the size — live or remembered), push a
  # corrective `size_owner` to this client only: a client that wrongly
  # believed it was the driver (stale role after a lost/gapped broadcast)
  # re-enters follower mode instead of rendering a grid the PTY does not
  # have.
  defp resize_with_correction(socket, rows, cols, opts \\ []) do
    result =
      if opts[:initial_attach?] do
        Dala.Terminal.Server.attach(
          socket.assigns.session_id,
          self(),
          socket.assigns.client_id,
          socket.assigns.device_id,
          rows,
          cols
        )
      else
        Dala.Terminal.Server.resize(
          socket.assigns.session_id,
          self(),
          socket.assigns.client_id,
          socket.assigns.device_id,
          rows,
          cols
        )
      end

    case result do
      {:ignored, %{owner: _owner} = snapshot} ->
        push(socket, "size_owner", snapshot)

      _applied_claimed_or_dead ->
        :ok
    end
  end

  defp high_water(%{alt: true}), do: @high_water_alt
  defp high_water(_fc), do: @high_water_normal

  # Base64 payload → decoded byte count, without decoding.
  defp decoded_size(encoded) do
    padding =
      case encoded do
        <<_::binary>> when binary_part(encoded, byte_size(encoded) - 2, 2) == "==" -> 2
        <<_::binary>> when binary_part(encoded, byte_size(encoded) - 1, 1) == "=" -> 1
        _ -> 0
      end

    div(byte_size(encoded), 4) * 3 - padding
  rescue
    _ -> byte_size(encoded)
  end

  # While skipping: once the client's acks have drained the backlog (or the
  # deadline fired), ask the session server for one repaint snapshot.
  defp maybe_flow_repaint(socket, opts \\ []) do
    fc = socket.assigns.fc
    drained = fc.sent - fc.acked <= @low_water

    if fc.skipping and not repaint_pending?(fc, socket) and (drained or opts[:force]) do
      # Flow recovery is always a viewport repaint. Scrollback remains lazy
      # and can be fetched later through `load_history`.
      request_repaint_once(socket, :screen)
    else
      socket
    end
  end

  # Queue at most one holder snapshot for this channel. The generation-bound
  # timer makes a lost holder response recoverable without unblocking a stale
  # response into a later request.
  defp request_repaint_once(socket, history, opts \\ []) do
    fc = socket.assigns.fc

    cond do
      opts[:upgrade?] == true and history == :full and
        Map.get(fc, :pending_history) == :screen and
          repaint_pending?(fc, socket) ->
        assign(socket, :fc, Map.put(fc, :queued_history, :full))

      repaint_pending?(fc, socket) ->
        socket

      true ->
        start_repaint(socket, history, opts)
    end
  end

  defp request_queued_history(socket) do
    fc = socket.assigns.fc
    if timer = Map.get(fc, :repaint_timer), do: Process.cancel_timer(timer)
    if timer = Map.get(fc, :repaint_retry_timer), do: Process.cancel_timer(timer)

    socket
    |> assign(
      :fc,
      Map.merge(fc, %{queued_history: nil, repaint_timer: nil, repaint_retry_timer: nil})
    )
    |> start_repaint(:full, preserve_barrier?: true)
  end

  defp start_repaint(socket, history, opts) do
    fc = socket.assigns.fc
    if timer = Map.get(fc, :repaint_timer), do: Process.cancel_timer(timer)
    if timer = Map.get(fc, :repaint_retry_timer), do: Process.cancel_timer(timer)

    generation = Map.get(fc, :repaint_generation, 0) + 1
    repaint_ref = make_ref()

    repaint_requested =
      if opts[:preserve_barrier?], do: fc.repaint_requested, else: opts[:initial?] != true

    initial_requested =
      if opts[:preserve_barrier?],
        do: Map.get(socket.assigns, :repaint_requested, false),
        else: opts[:initial?] == true

    fc =
      Map.merge(fc, %{
        repaint_requested: repaint_requested,
        skipping: fc.skipping or opts[:skip?] == true,
        pending_history: history,
        queued_history: nil,
        repaint_generation: generation,
        repaint_ref: repaint_ref,
        repaint_timer: nil,
        repaint_retry_timer: nil,
        repaint_timed_out: false,
        repaint_fallback_sent:
          if(opts[:retry?], do: Map.get(fc, :repaint_fallback_sent, false), else: false)
      })

    socket =
      socket
      |> assign(:fc, fc)
      |> assign(:repaint_requested, initial_requested)

    case Dala.Terminal.Server.request_repaint(
           socket.assigns.session_id,
           self(),
           history: history,
           ref: repaint_ref
         ) do
      :ok ->
        timer =
          Process.send_after(
            self(),
            {:repaint_timeout, generation, repaint_ref},
            @repaint_timeout_ms
          )

        assign(socket, :fc, %{fc | repaint_timer: timer})

      {:error, :not_running} ->
        defer_repaint(socket, keep_ref?: false)
    end
  end

  defp repaint_pending?(fc, socket),
    do:
      Map.get(fc, :repaint_ref) != nil or Map.get(fc, :repaint_retry_timer) != nil or
        Map.get(fc, :repaint_requested, false) or
        Map.get(socket.assigns, :repaint_requested, false)

  defp repaint_response_matches?(fc, socket, nil) do
    # Four-tuple responses are from pre-ref servers. Accept them only while a
    # request is pending; once a timed-out generation was settled, a late old
    # response must not be interpreted as a fresh replay.
    is_nil(Map.get(fc, :repaint_ref)) and is_nil(Map.get(fc, :repaint_retry_timer)) and
      repaint_pending?(fc, socket)
  end

  defp repaint_response_matches?(fc, _socket, repaint_ref),
    do: is_reference(Map.get(fc, :repaint_ref)) and Map.get(fc, :repaint_ref) == repaint_ref

  defp clear_repaint(fc, opts) do
    if timer = Map.get(fc, :repaint_timer), do: Process.cancel_timer(timer)
    if timer = Map.get(fc, :repaint_retry_timer), do: Process.cancel_timer(timer)

    bytes = Keyword.get(opts, :bytes, 0)

    Map.merge(fc, %{
      skipping: false,
      repaint_requested: false,
      pending_history: nil,
      queued_history: nil,
      repaint_ref: nil,
      repaint_timer: nil,
      repaint_retry_timer: nil,
      repaint_timed_out: false,
      repaint_fallback_sent: false,
      sent: fc.sent + bytes
    })
  end

  defp defer_repaint(socket, opts) do
    fc = socket.assigns.fc
    if timer = Map.get(fc, :repaint_timer), do: Process.cancel_timer(timer)
    if timer = Map.get(fc, :repaint_retry_timer), do: Process.cancel_timer(timer)

    history = Map.get(fc, :queued_history) || Map.get(fc, :pending_history) || :screen
    generation = Map.get(fc, :repaint_generation, 0)
    retry_timer = Process.send_after(self(), {:repaint_retry, generation}, @repaint_retry_ms)

    initial? =
      Map.get(socket.assigns, :initial_repaint_timed_out, false) or
        (Map.get(socket.assigns, :repaint_requested, false) and not fc.repaint_requested)

    fc =
      Map.merge(fc, %{
        skipping: true,
        pending_history: history,
        queued_history: nil,
        repaint_ref: if(opts[:keep_ref?], do: fc.repaint_ref, else: nil),
        repaint_timer: nil,
        repaint_retry_timer: retry_timer,
        repaint_timed_out: true
      })

    socket =
      socket
      |> assign(:fc, fc)
      |> assign(:repaint_requested, false)
      |> assign(:initial_repaint_timed_out, initial?)

    if Map.get(fc, :repaint_fallback_sent, false) do
      socket
    else
      socket
      |> push_replay("", 0, false, false, true)
      |> assign(:fc, %{fc | repaint_fallback_sent: true})
    end
  end

  # Pushes one repaint as a series of replay batches. Every batch carries the
  # repaint's seq watermark; the last one is flagged `done` so the client can
  # uncover and re-enable input. `reset` marks a mid-session flow-control
  # snapshot: the client must clear the screen first (a join-time replay
  # resets implicitly).
  defp push_replay(
         socket,
         data,
         seq,
         reset \\ false,
         history_loaded \\ true,
         retrying \\ false
       ) do
    chunks = chunk_binary(data, @replay_batch_bytes)

    chunks
    |> Enum.with_index(1)
    |> Enum.each(fn {chunk, index} ->
      push(socket, "replay", %{
        data: Base.encode64(chunk),
        seq: seq,
        done: index == length(chunks),
        # Reset is an edge, not a property of every batch. Repeating it would
        # make the browser clear xterm before each chunk and retain only the
        # tail of snapshots larger than @replay_batch_bytes.
        reset: reset and index == 1,
        historyLoaded: history_loaded,
        retrying: retrying
      })
    end)

    assign(socket, :replayed, true)
  end

  defp chunk_binary("", _size), do: [""]

  defp chunk_binary(data, size) when byte_size(data) <= size, do: [data]

  defp chunk_binary(data, size) do
    <<head::binary-size(size), rest::binary>> = data
    [head | chunk_binary(rest, size)]
  end
end
