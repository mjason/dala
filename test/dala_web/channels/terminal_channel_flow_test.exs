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
    assert_push "replay", %{reset: true, done: done}, 8_000
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

  test "normal-buffer watermark is much higher" do
    session = create_session!()
    socket = join_and_attach!(session.id)

    push(socket, "ack", %{"bytes" => 1, "alt" => false})
    Process.sleep(50)

    # 256 KB is far below the normal-buffer watermark: nothing is dropped.
    for seq <- 1..8, do: broadcast_chunk(session.id, 4000 + seq)
    assert count_output_pushes() == 8
  end
end
