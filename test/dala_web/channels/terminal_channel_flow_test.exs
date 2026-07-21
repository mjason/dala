defmodule DalaWeb.TerminalChannelFlowTest do
  @moduledoc """
  Per-client output flow control: the channel tracks sent-minus-acked bytes;
  past the watermark it stops streaming (drops chunks), and once the client's
  acks drain it sends ONE repaint snapshot (reset: true) and resumes — the
  mosh idea, so a slow link never queues seconds of stale bytes ahead of the
  keystroke echo.
  """
  use DalaWeb.ChannelCase, async: false

  alias Dala.Terminal.{Holder, Server}

  @chunk 32 * 1024

  defp create_session! do
    session = Dala.Terminal.create_session!(%{shell: "/bin/bash"})

    on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      File.rm(Holder.exit_path(to_string(session.id)))
      File.rm(Holder.final_path(to_string(session.id)))
      File.rm(Holder.text_final_path(to_string(session.id)))
    end)

    session
  end

  defp join_and_attach!(session_id) do
    {:ok, _reply, socket} =
      DalaWeb.UserSocket
      |> socket(nil, %{})
      |> subscribe_and_join(DalaWeb.TerminalChannel, "terminal:#{session_id}")

    push(socket, "attach", %{"rows" => 24, "cols" => 80})
    drain_replay()
    socket
  end

  defp drain_replay do
    assert_push "replay", %{done: done}, 8_000
    unless done, do: drain_replay()
  end

  defp broadcast_chunk(session_id, seq, bytes \\ @chunk) do
    data = :binary.copy("x", bytes)

    DalaWeb.Endpoint.broadcast("terminal:#{session_id}", "output", %{
      data: Base.encode64(data),
      seq: seq
    })

    bytes
  end

  defp closed_tcp_socket do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    {:ok, peer} = :gen_tcp.accept(listener)

    :ok = :gen_tcp.close(peer)
    :ok = :gen_tcp.close(client)
    :ok = :gen_tcp.close(listener)

    client
  end

  # Count only OUR flood chunks — the live bash session emits its own
  # output (prompt, motd) that would skew exact-count assertions.
  defp count_output_pushes(acc \\ 0) do
    expected = byte_size(Base.encode64(:binary.copy("x", @chunk)))

    receive do
      %Phoenix.Socket.Message{event: "output", payload: %{data: data}}
      when byte_size(data) == expected ->
        count_output_pushes(acc + 1)

      %Phoenix.Socket.Message{event: "output"} ->
        count_output_pushes(acc)
    after
      300 -> acc
    end
  end

  test "clients that never ack get the full stream (legacy behavior)" do
    session = create_session!()
    join_and_attach!(session.id)

    for seq <- 1..40, do: broadcast_chunk(session.id, 1000 + seq)
    assert count_output_pushes() == 40
  end

  test "output sent before the first ack is charged to the flow ledger" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    before = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc

    refute before.enabled
    broadcast_chunk(session.id, 1_999)
    assert_push "output", %{seq: 1_999}, 2_000

    charged = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
    assert charged.sent == before.sent + @chunk

    push(socket, "ack", %{"bytes" => @chunk, "alt" => true})
    _ = push(socket, "resize", %{"rows" => 24, "cols" => 80})

    enabled = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
    assert enabled.enabled
    assert enabled.acked == @chunk
    assert enabled.sent - enabled.acked == before.sent

    push(socket, "ack", %{"bytes" => 100 * @chunk, "alt" => true})
    _ = push(socket, "resize", %{"rows" => 24, "cols" => 80})

    clamped = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
    assert clamped.acked == clamped.sent
  end

  test "acked clients stop receiving past the alt watermark, then resume via flow repaint" do
    session = create_session!()
    socket = join_and_attach!(session.id)

    # First ack enables flow control and declares the alt screen (128 KB
    # high watermark).
    push(socket, "ack", %{"bytes" => 1, "alt" => true})
    # ack is async — give the channel a beat before flooding
    _ = push(socket, "resize", %{"rows" => 24, "cols" => 80})
    Process.sleep(50)

    # 8 × 32 KB = 256 KB — twice the watermark. Only ~4 chunks fit.
    for seq <- 1..8, do: broadcast_chunk(session.id, 2000 + seq)
    pushed = count_output_pushes()
    assert pushed >= 3 and pushed <= 5

    # Drain: acknowledge everything that was pushed → the channel must fetch
    # a repaint snapshot and send it as a replay marked reset: true.
    push(socket, "ack", %{"bytes" => pushed * @chunk, "alt" => true})
    # Flow-control recovery is viewport-only. Scrollback stays lazy so a
    # busy session does not make the reveal parse its entire history.
    assert_push "replay", %{reset: true, historyLoaded: false, done: done}, 8_000
    unless done, do: drain_replay()

    # The viewport repaint must not mark history as loaded: an explicit
    # scroll/search request still fetches the full bounded snapshot later.
    push(socket, "load_history", %{})
    assert_push "replay", %{reset: true, historyLoaded: true, done: done}, 8_000
    unless done, do: drain_replay()

    # Streaming resumes after the snapshot.
    broadcast_chunk(session.id, 3000)
    assert_push "output", %{seq: 3000}, 2_000
  end

  test "a takeover's reset replay lands while skipping, then output resumes" do
    session = create_session!()
    socket = join_and_attach!(session.id)

    # Enable flow control on the alt watermark and flood past it: the
    # channel enters skipping.
    push(socket, "ack", %{"bytes" => 1, "alt" => true})
    Process.sleep(50)
    for seq <- 1..8, do: broadcast_chunk(session.id, 2000 + seq)
    pushed = count_output_pushes()
    assert pushed >= 3 and pushed <= 5

    # Another client takes over the size while we sit in skipping. The
    # takeover snapshot must reach us as a reset replay — repaint_reset
    # settles the in-flight skip state instead of being swallowed by it.
    Server.claim_size(session.id, self(), "other-client", "other-device", 21, 46)
    assert_push "replay", %{reset: true, done: done}, 8_000
    unless done, do: drain_replay()

    # Once the acks catch up, live output streams again (the reset replay
    # cleared `skipping`).
    push(socket, "ack", %{"bytes" => 100 * @chunk, "alt" => true})
    broadcast_chunk(session.id, 5000)
    assert_push "output", %{seq: 5000}, 2_000
  end

  test "an all-client repaint does not settle a newer targeted repaint" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    server = Server.whereis(session.id)

    # Hold the targeted holder request in the Server mailbox. A size-takeover
    # snapshot can already have been sent to this Channel before the catch-up
    # request starts, yet arrive in its mailbox afterwards.
    :ok = :sys.suspend(server)

    try do
      push(socket, "catch_up", %{})
      eventually(fn -> :sys.get_state(socket.channel_pid).assigns.fc.repaint_ref != nil end)

      before = Phoenix.Channel.Server.socket(socket.channel_pid)
      repaint_ref = before.assigns.fc.repaint_ref
      repaint_timer = before.assigns.fc.repaint_timer
      sent_before = before.assigns.fc.sent

      send(socket.channel_pid, {:repaint_reset, "ALL", 7_100, true})
      refute_push "replay", %{}, 100

      preserved = Phoenix.Channel.Server.socket(socket.channel_pid)
      assert preserved.assigns.fc.repaint_ref == repaint_ref
      assert preserved.assigns.fc.repaint_timer == repaint_timer
      assert preserved.assigns.fc.pending_history == :screen
      assert preserved.assigns.fc.repaint_requested
      assert preserved.assigns.fc.skipping
      assert preserved.assigns.fc.sent == sent_before

      # Only the matching targeted response settles the request and releases
      # skipping. It must still be delivered as a reset replay.
      send(socket.channel_pid, {:repaint, "TARGET", 7_101, false, repaint_ref})

      assert_push "replay",
                  %{
                    data: "VEFSR0VU",
                    seq: 7_101,
                    reset: true,
                    historyLoaded: false,
                    done: true
                  },
                  2_000

      settled = Phoenix.Channel.Server.socket(socket.channel_pid)
      assert is_nil(settled.assigns.fc.repaint_ref)
      assert is_nil(settled.assigns.fc.repaint_timer)
      assert is_nil(settled.assigns.fc.pending_history)
      refute settled.assigns.fc.repaint_requested
      refute settled.assigns.fc.skipping
    after
      if Process.alive?(server), do: :ok = :sys.resume(server)
    end
  end

  test "an older all-client repaint cannot clear a ref-less authoritative retry barrier" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    server = Server.whereis(session.id)

    :ok = :sys.suspend(server)

    try do
      push(socket, "catch_up", %{})
      eventually(fn -> :sys.get_state(socket.channel_pid).assigns.fc.repaint_ref != nil end)

      requested = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc

      # Queue-full and holder-unavailable responses never reached the holder,
      # so defer_repaint clears their ref while retaining a retry barrier.
      send(socket.channel_pid, {:repaint, "", 0, false, requested.repaint_ref})
      assert_push "replay", %{retrying: true, done: true}, 2_000

      fallback = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      assert is_nil(fallback.repaint_ref)
      assert is_reference(fallback.repaint_retry_timer)
      assert fallback.pending_history == :screen
      assert fallback.skipping
      Process.cancel_timer(fallback.repaint_retry_timer)

      # This response can have been ahead of the rejected targeted request in
      # the Server/holder FIFO. Even its done frame must stay behind the gate:
      # it cannot prove that it covers the output discarded by catch_up.
      send(socket.channel_pid, {:repaint_reset, "OLDER-ALL", 7_150, true})
      refute_push "replay", %{}, 100

      preserved = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      assert preserved.repaint_retry_timer == fallback.repaint_retry_timer
      assert preserved.pending_history == :screen
      assert preserved.repaint_timed_out
      assert preserved.repaint_requested
      assert preserved.skipping

      send(socket.channel_pid, {:repaint_retry, fallback.repaint_generation})

      eventually(fn ->
        fc = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
        is_reference(fc.repaint_ref) and fc.repaint_ref != requested.repaint_ref
      end)

      retry = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      send(socket.channel_pid, {:repaint, "AUTHORITATIVE", 7_151, false, retry.repaint_ref})

      assert_push "replay", %{data: "QVVUSE9SSVRBVElWRQ==", reset: true}, 2_000
      refute Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc.skipping
    after
      if Process.alive?(server), do: :ok = :sys.resume(server)
    end
  end

  test "a pre-ref flow repaint remains pending and authoritative across code reload" do
    session = create_session!()
    socket = join_and_attach!(session.id)

    :sys.replace_state(socket.channel_pid, fn channel_socket ->
      fc =
        Map.merge(channel_socket.assigns.fc, %{
          skipping: true,
          repaint_requested: true,
          pending_history: nil,
          repaint_ref: nil,
          repaint_timer: nil,
          repaint_retry_timer: nil
        })

      assigns =
        channel_socket.assigns
        |> Map.put(:fc, fc)
        |> Map.put(:repaint_requested, false)
        |> Map.put(:replayed, true)

      %{channel_socket | assigns: assigns}
    end)

    # A request queued before the ref protocol has only fc.repaint_requested
    # to identify it. Its four-tuple response must still settle the barrier.
    send(socket.channel_pid, {:repaint, "PRE-REF", 7_175, true})

    assert_push "replay",
                %{data: "UFJFLVJFRg==", seq: 7_175, reset: true, done: true},
                2_000

    settled = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
    refute settled.repaint_requested
    refute settled.skipping
  end

  test "load_history upgrades an in-flight viewport repaint before revealing it" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    server = Server.whereis(session.id)

    :ok = :sys.suspend(server)

    try do
      push(socket, "catch_up", %{})
      eventually(fn -> :sys.get_state(socket.channel_pid).assigns.fc.repaint_ref != nil end)

      screen_state = Phoenix.Channel.Server.socket(socket.channel_pid)
      screen_ref = screen_state.assigns.fc.repaint_ref

      push(socket, "load_history", %{})
      _ = :sys.get_state(socket.channel_pid)

      queued = Phoenix.Channel.Server.socket(socket.channel_pid)
      assert queued.assigns.fc.repaint_ref == screen_ref
      assert queued.assigns.fc.pending_history == :screen
      assert queued.assigns.fc.queued_history == :full
      assert queued.assigns.fc.skipping
      assert queued.assigns.fc.repaint_requested

      send(socket.channel_pid, {:repaint, "SCREEN", 7_200, false, screen_ref})

      eventually(fn ->
        state = :sys.get_state(socket.channel_pid).assigns.fc
        state.pending_history == :full and state.repaint_ref != screen_ref
      end)

      upgraded = Phoenix.Channel.Server.socket(socket.channel_pid)
      full_ref = upgraded.assigns.fc.repaint_ref
      refute_push "replay", %{}, 100
      assert is_reference(full_ref)
      assert is_nil(upgraded.assigns.fc.queued_history)
      assert upgraded.assigns.fc.skipping
      assert upgraded.assigns.fc.repaint_requested

      send(socket.channel_pid, {:repaint, "FULL", 7_201, true, full_ref})

      assert_push "replay",
                  %{
                    data: "RlVMTA==",
                    seq: 7_201,
                    reset: true,
                    historyLoaded: true,
                    done: true
                  },
                  2_000

      settled = Phoenix.Channel.Server.socket(socket.channel_pid)
      assert is_nil(settled.assigns.fc.repaint_ref)
      assert is_nil(settled.assigns.fc.pending_history)
      assert is_nil(settled.assigns.fc.queued_history)
      refute settled.assigns.fc.skipping
      refute settled.assigns.fc.repaint_requested
    after
      if Process.alive?(server), do: :ok = :sys.resume(server)
    end
  end

  test "a full viewport response satisfies queued load_history without a follow-up" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    server = Server.whereis(session.id)

    :ok = :sys.suspend(server)

    try do
      push(socket, "catch_up", %{})
      eventually(fn -> :sys.get_state(socket.channel_pid).assigns.fc.repaint_ref != nil end)

      screen_ref =
        socket.channel_pid
        |> Phoenix.Channel.Server.socket()
        |> then(& &1.assigns.fc.repaint_ref)

      push(socket, "load_history", %{})
      _ = :sys.get_state(socket.channel_pid)

      send(socket.channel_pid, {:repaint, "ALREADY_FULL", 7_202, true, screen_ref})

      assert_push "replay",
                  %{
                    data: "QUxSRUFEWV9GVUxM",
                    seq: 7_202,
                    reset: true,
                    historyLoaded: true,
                    done: true
                  },
                  2_000

      settled = Phoenix.Channel.Server.socket(socket.channel_pid)
      assert is_nil(settled.assigns.fc.repaint_ref)
      assert is_nil(settled.assigns.fc.pending_history)
      assert is_nil(settled.assigns.fc.queued_history)
      refute settled.assigns.fc.skipping
      refute settled.assigns.fc.repaint_requested
    after
      if Process.alive?(server), do: :ok = :sys.resume(server)
    end
  end

  test "an unavailable viewport repaint preserves queued history until an authoritative retry" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    server = Server.whereis(session.id)

    :ok = :sys.suspend(server)

    try do
      push(socket, "catch_up", %{})
      eventually(fn -> :sys.get_state(socket.channel_pid).assigns.fc.repaint_ref != nil end)

      repaint_ref =
        socket.channel_pid
        |> Phoenix.Channel.Server.socket()
        |> then(& &1.assigns.fc.repaint_ref)

      push(socket, "load_history", %{})
      _ = :sys.get_state(socket.channel_pid)
      assert Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc.queued_history == :full

      send(socket.channel_pid, {:repaint, "", 0, false, repaint_ref})

      assert_push "replay",
                  %{
                    data: "",
                    seq: 0,
                    reset: false,
                    historyLoaded: false,
                    retrying: true,
                    done: true
                  },
                  2_000

      fallback = Phoenix.Channel.Server.socket(socket.channel_pid)
      assert is_nil(fallback.assigns.fc.repaint_ref)
      assert fallback.assigns.fc.pending_history == :full
      assert is_nil(fallback.assigns.fc.queued_history)
      assert fallback.assigns.fc.skipping
      assert fallback.assigns.fc.repaint_requested
      assert fallback.assigns.fc.repaint_timed_out
      assert is_reference(fallback.assigns.fc.repaint_retry_timer)

      generation = fallback.assigns.fc.repaint_generation
      send(socket.channel_pid, {:repaint_retry, generation})

      eventually(fn ->
        fc = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
        fc.pending_history == :full and is_reference(fc.repaint_ref)
      end)

      retry = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      send(socket.channel_pid, {:repaint, "FULL-RETRY", 7_250, true, retry.repaint_ref})

      assert_push "replay",
                  %{reset: true, historyLoaded: true, retrying: false, done: true},
                  2_000

      settled = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      refute settled.skipping
      refute settled.repaint_requested
      refute settled.repaint_timed_out
      assert is_nil(settled.repaint_retry_timer)
    after
      if Process.alive?(server), do: :ok = :sys.resume(server)
    end
  end

  test "normal-buffer watermark is much higher" do
    session = create_session!()
    socket = join_and_attach!(session.id)

    push(socket, "ack", %{"bytes" => 1, "alt" => false})
    Process.sleep(50)

    # 256 KB is far below the normal-buffer watermark: nothing is dropped.
    for seq <- 1..8, do: broadcast_chunk(session.id, 4000 + seq)
    assert count_output_pushes() == 8
  end

  test "a multi-batch reset replay clears the browser only on its first batch" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    repaint = :binary.copy("r", 192 * 1024 + 1)

    send(socket.channel_pid, {:repaint_reset, repaint, 7_001, true})

    assert_push "replay", %{seq: 7_001, reset: true, done: false, data: first}, 2_000
    assert byte_size(Base.decode64!(first)) == 192 * 1024

    assert_push "replay", %{seq: 7_001, reset: false, done: true, data: last}, 2_000
    assert Base.decode64!(last) == "r"
  end

  test "a failed holder repaint preserves the screen and gates output until repair" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    server = Server.whereis(session.id)
    holder_socket = :sys.get_state(server).socket
    failed_socket = closed_tcp_socket()

    :sys.replace_state(server, fn state ->
      :ok = :inet.setopts(holder_socket, active: false)
      Map.put(state, :socket, failed_socket)
    end)

    try do
      push(socket, "catch_up", %{})

      assert_push "replay",
                  %{
                    data: "",
                    seq: 0,
                    reset: false,
                    historyLoaded: false,
                    retrying: true,
                    done: true
                  },
                  2_000

      channel_socket = Phoenix.Channel.Server.socket(socket.channel_pid)
      assert is_nil(channel_socket.assigns.fc.repaint_ref)
      assert channel_socket.assigns.fc.repaint_requested
      assert channel_socket.assigns.fc.skipping
      assert channel_socket.assigns.fc.repaint_timed_out
      assert is_reference(channel_socket.assigns.fc.repaint_retry_timer)

      broadcast_chunk(session.id, 7_002, 64)
      refute_push "output", %{seq: 7_002}, 100
    after
      if Process.alive?(server) do
        :sys.replace_state(server, fn state ->
          :ok = :inet.setopts(holder_socket, active: true)
          Map.put(state, :socket, holder_socket)
        end)
      end
    end

    # Once the holder socket is usable again, a new authoritative snapshot
    # repairs the skipped window and only then releases incremental output.
    push(socket, "catch_up", %{})
    assert_push "replay", %{reset: true, historyLoaded: false, done: done}, 8_000
    unless done, do: drain_replay()

    broadcast_chunk(session.id, 7_003, 64)
    assert_push "output", %{seq: 7_003}, 2_000
  end

  test "queued history replaces a timed-out viewport repaint without revealing a fallback" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    server = Server.whereis(session.id)

    :ok = :sys.suspend(server)

    try do
      push(socket, "catch_up", %{})
      eventually(fn -> :sys.get_state(socket.channel_pid).assigns.fc.repaint_ref != nil end)

      screen = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      screen_ref = screen.repaint_ref

      push(socket, "load_history", %{})
      _ = :sys.get_state(socket.channel_pid)
      assert Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc.queued_history == :full

      send(socket.channel_pid, {:repaint_timeout, screen.repaint_generation, screen_ref})

      eventually(fn ->
        fc = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
        fc.pending_history == :full and fc.repaint_ref != screen_ref
      end)

      upgraded = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      full_ref = upgraded.repaint_ref
      refute_push "replay", %{}, 100
      assert upgraded.skipping
      assert upgraded.repaint_requested

      send(socket.channel_pid, {:repaint, "STALE-SCREEN", 122, false, screen_ref})
      refute_push "replay", %{}, 100

      send(socket.channel_pid, {:repaint, "FULL-AFTER-TIMEOUT", 123, true, full_ref})

      assert_push "replay",
                  %{
                    data: "RlVMTC1BRlRFUi1USU1FT1VU",
                    seq: 123,
                    reset: true,
                    historyLoaded: true,
                    done: true
                  },
                  2_000

      settled = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      assert is_nil(settled.repaint_ref)
      assert is_nil(settled.pending_history)
      refute settled.skipping
      refute settled.repaint_requested
    after
      if Process.alive?(server), do: :ok = :sys.resume(server)
    end
  end

  test "a lost catch-up repaint times out, accepts its late repair, and resumes output" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    server = Server.whereis(session.id)

    # Stop the session server immediately after the channel queues the holder
    # request. The channel must recover on its own rather than dropping every
    # subsequent output forever.
    :ok = :sys.suspend(server)

    try do
      push(socket, "catch_up", %{})

      eventually(fn -> :sys.get_state(socket.channel_pid).assigns.fc.repaint_ref != nil end)
      channel_socket = Phoenix.Channel.Server.socket(socket.channel_pid)
      %{repaint_generation: generation, repaint_ref: repaint_ref} = channel_socket.assigns.fc

      send(socket.channel_pid, {:repaint_timeout, generation, repaint_ref})

      assert_push "replay",
                  %{
                    data: "",
                    seq: 0,
                    reset: false,
                    historyLoaded: false,
                    retrying: true,
                    done: true
                  },
                  2_000

      settled = Phoenix.Channel.Server.socket(socket.channel_pid)
      assert settled.assigns.fc.skipping
      assert settled.assigns.fc.repaint_requested
      assert settled.assigns.fc.repaint_timed_out
      assert settled.assigns.fc.repaint_ref == repaint_ref
      assert is_reference(settled.assigns.fc.repaint_retry_timer)

      broadcast_chunk(session.id, 122, 64)
      refute_push "output", %{seq: 122}, 100

      # The exact timed-out generation remains authoritative: it repairs output
      # discarded while catch-up was skipping. A newer request would replace
      # the ref and make this response stale instead.
      send(socket.channel_pid, {:repaint, "REPAIRED", 123, true, repaint_ref})

      assert_push "replay",
                  %{
                    data: "UkVQQUlSRUQ=",
                    seq: 123,
                    reset: true,
                    historyLoaded: true,
                    done: true
                  },
                  2_000

      repaired = Phoenix.Channel.Server.socket(socket.channel_pid)
      assert is_nil(repaired.assigns.fc.repaint_ref)
      refute repaired.assigns.fc.repaint_timed_out
    after
      if Process.alive?(server), do: :ok = :sys.resume(server)
    end

    broadcast_chunk(session.id, 1, 64)
    assert_push "output", %{seq: 1}, 2_000
  end

  test "a repaint requested after the session server died settles immediately" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    server = Server.whereis(session.id)
    ref = Process.monitor(server)
    :ok = DynamicSupervisor.terminate_child(Dala.Terminal.ServerSupervisor, server)
    assert_receive {:DOWN, ^ref, :process, ^server, _reason}, 5_000
    eventually(fn -> not Server.alive?(session.id) end)

    push(socket, "catch_up", %{})

    assert_push "replay",
                %{
                  data: "",
                  seq: 0,
                  reset: false,
                  historyLoaded: false,
                  retrying: true,
                  done: true
                },
                2_000

    channel_socket = Phoenix.Channel.Server.socket(socket.channel_pid)
    assert channel_socket.assigns.fc.skipping
    assert channel_socket.assigns.fc.repaint_requested
    assert channel_socket.assigns.fc.repaint_timed_out

    # The topic can still deliver a final in-flight output message after the
    # BEAM owner dies. It must stay gated because no snapshot covered it.
    broadcast_chunk(session.id, 6_002, 64)
    refute_push "output", %{seq: 6_002}, 100

    # An explicit reset on a dead session serves the holder's final screen and
    # is authoritative, so it can safely reopen the incremental stream.
    push(socket, "repaint", %{})
    assert_push "replay", %{reset: true, done: done}, 2_000
    unless done, do: drain_replay()

    broadcast_chunk(session.id, 6_003, 64)
    assert_push "output", %{seq: 6_003}, 2_000
  end

  test "an exit broadcast cancels a pending authoritative repaint retry" do
    session = create_session!()
    socket = join_and_attach!(session.id)
    server = Server.whereis(session.id)
    :ok = :sys.suspend(server)

    try do
      push(socket, "catch_up", %{})
      eventually(fn -> :sys.get_state(socket.channel_pid).assigns.fc.repaint_ref != nil end)

      fc = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      send(socket.channel_pid, {:repaint_timeout, fc.repaint_generation, fc.repaint_ref})
      assert_push "replay", %{retrying: true}, 2_000

      fallback = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      assert is_reference(fallback.repaint_retry_timer)
      assert fallback.skipping

      DalaWeb.Endpoint.broadcast("terminal:#{session.id}", "exit", %{
        id: session.id,
        exitCode: 0
      })

      assert_push "exit", %{id: _, exitCode: 0}, 2_000
      settled = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      assert is_nil(settled.repaint_retry_timer)
      assert is_nil(settled.repaint_ref)
      refute settled.repaint_timed_out
      refute settled.skipping
    after
      if Process.alive?(server), do: :ok = :sys.resume(server)
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
