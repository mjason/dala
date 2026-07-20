defmodule DalaWeb.TerminalChannelRepaintTest do
  @moduledoc """
  Client-initiated repaint (the toolbar Reset button): pushing "repaint"
  fetches one holder snapshot and delivers it to THIS client as a reset
  replay (`reset: true` — clear and replace). A `\\f` keystroke only redraws
  a bare shell prompt; inside zellij/claude-code/any TUI it is swallowed (or
  typed), leaving the locally-reset terminal blank — the holder snapshot is
  the only thing that always repaints the full screen.

  Flow-control interplay: a snapshot already in flight for this client (the
  skip-to-repaint path) also lands as a reset replay, so a concurrent user
  reset must NOT queue a second one.
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

  # Collects one full replay (until done: true) and returns its decoded bytes
  # plus the reset flag of the first batch.
  defp collect_replay(timeout \\ 8_000, acc \\ "", reset \\ nil) do
    assert_push "replay",
                %{done: done, reset: batch_reset, data: data, historyLoaded: true},
                timeout

    acc = acc <> Base.decode64!(data)
    reset = if is_nil(reset), do: batch_reset, else: reset
    if done, do: {acc, reset}, else: collect_replay(timeout, acc, reset)
  end

  # Waits until the session's live output contains `marker` (the echo of an
  # input we sent), so the holder snapshot is guaranteed to cover it.
  defp await_output_containing(marker, deadline_ms \\ 8_000) do
    receive do
      %Phoenix.Socket.Message{event: "output", payload: %{data: data}} ->
        if String.contains?(Base.decode64!(data), marker) do
          :ok
        else
          await_output_containing(marker, deadline_ms)
        end
    after
      deadline_ms -> flunk("no output containing #{inspect(marker)}")
    end
  end

  defp wait_until(fun, deadline_ms \\ 8_000) do
    if fun.() do
      :ok
    else
      if deadline_ms <= 0, do: flunk("condition never became true")
      Process.sleep(50)
      wait_until(fun, deadline_ms - 50)
    end
  end

  defp broadcast_chunk(session_id, seq, bytes \\ @chunk) do
    data = :binary.copy("x", bytes)

    DalaWeb.Endpoint.broadcast("terminal:#{session_id}", "output", %{
      data: Base.encode64(data),
      seq: seq
    })

    bytes
  end

  # Count only OUR flood chunks — the live bash session emits its own output.
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

  test "a plain client's repaint push yields a reset replay with the holder snapshot" do
    session = create_session!()
    socket = join_and_attach!(session.id)

    # Print a marker so the snapshot has verifiable content.
    push(socket, "input", %{"data" => "printf 'REPAINT_MARK\\n'\n"})
    await_output_containing("REPAINT_MARK")

    push(socket, "repaint", %{})
    {data, reset} = collect_replay()

    assert reset == true
    assert String.contains?(data, "REPAINT_MARK")
  end

  test "an acked flow-control client gets the reset replay and output keeps streaming" do
    session = create_session!()
    socket = join_and_attach!(session.id)

    # Enable flow control (client acks) without ever going over the watermark.
    push(socket, "ack", %{"bytes" => 1, "alt" => false})
    _ = push(socket, "resize", %{"rows" => 24, "cols" => 80})

    push(socket, "repaint", %{})
    {_data, reset} = collect_replay()
    assert reset == true

    # The snapshot settled into the flow ledger — live output still flows.
    broadcast_chunk(session.id, 9000)
    assert_push "output", %{seq: 9000}, 2_000
  end

  test "a skipping client's reset does not double-repaint" do
    session = create_session!()
    socket = join_and_attach!(session.id)

    # Enter skipping: alt watermark (128 KB), flood 256 KB.
    push(socket, "ack", %{"bytes" => 1, "alt" => true})
    _ = push(socket, "resize", %{"rows" => 24, "cols" => 80})
    for seq <- 1..8, do: broadcast_chunk(session.id, 2000 + seq)
    pushed = count_output_pushes()
    assert pushed >= 3 and pushed <= 5

    # User hits Reset while the client is skipping: this requests the ONE
    # snapshot that settles both the reset and the skip. It must arrive
    # promptly — well before the 4s flow-repaint deadline would have fired
    # anyway (a vacuous pass otherwise).
    push(socket, "repaint", %{})
    {_data, reset} = collect_replay(2_500)
    assert reset == true

    # Draining the acks afterwards must NOT trigger a second flow repaint —
    # the reset snapshot already cleared the skip state.
    push(socket, "ack", %{"bytes" => 100 * @chunk, "alt" => true})
    refute_push "replay", %{reset: true}, 1_500

    # And live output streams again.
    broadcast_chunk(session.id, 5000)
    assert_push "output", %{seq: 5000}, 2_000
  end

  test "a repaint push on an exited session re-serves the final screen" do
    session = create_session!()
    socket = join_and_attach!(session.id)

    # Kill the shell and wait for the exit broadcast, then for the session
    # server to actually be gone (the broadcast races its :stop) and for the
    # holder's final-screen file to exist.
    push(socket, "input", %{"data" => "printf 'FINAL_MARK\\n'; exit\n"})
    assert_push "exit", %{}, 8_000

    wait_until(fn ->
      not Server.alive?(session.id) and
        File.exists?(Holder.final_path(to_string(session.id)))
    end)

    push(socket, "repaint", %{})
    {data, reset} = collect_replay()

    assert reset == true
    assert String.contains?(data, "FINAL_MARK")
  end
end
