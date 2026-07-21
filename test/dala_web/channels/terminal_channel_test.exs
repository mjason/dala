defmodule DalaWeb.TerminalChannelTest do
  use DalaWeb.ChannelCase, async: false

  alias Dala.Terminal.{Holder, Server}

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

  defp join!(session_id) do
    DalaWeb.UserSocket
    |> socket(nil, %{})
    |> subscribe_and_join(DalaWeb.TerminalChannel, "terminal:#{session_id}")
  end

  # The client reports its viewport after joining; only then is the repaint
  # generated (sizing first lets the emulator reflow to the right width).
  defp attach!(socket, rows \\ 24, cols \\ 80) do
    push(socket, "attach", %{"rows" => rows, "cols" => cols})
    socket
  end

  test "join delivers the holder's synthesized repaint and reports status" do
    session = create_session!()

    # Put something on the screen, then join fresh: the repaint must carry it.
    Server.input(session.id, "echo repaint-me-$((40 + 2))\r")
    Process.sleep(300)

    assert {:ok, %{status: :running}, socket} = join!(session.id)
    attach!(socket)

    assert_replay_containing("repaint-me-42", false)
  end

  test "the initial timeout requests the current screen instead of revealing an empty stream" do
    session = create_session!()
    Server.input(session.id, "echo LATE-ATTACH-SCREEN\r")
    Process.sleep(300)

    assert {:ok, _reply, socket} = join!(session.id)
    _ = :sys.get_state(socket.channel_pid)
    send(socket.channel_pid, :initial_repaint_timeout)

    assert_push "replay",
                %{data: data, reset: false, historyLoaded: false, done: true},
                5_000

    timed_out = Phoenix.Channel.Server.socket(socket.channel_pid)
    refute timed_out.assigns.initial_repaint_timed_out
    assert Base.decode64!(data) =~ "LATE-ATTACH-SCREEN"

    # A viewport report can still resize ownership, but the timeout repaint is
    # already authoritative and attach must not start a duplicate generation.
    attach!(socket)
    refute_push "replay", %{}, 100
  end

  test "a late initial snapshot resets the stream after its timeout fallback" do
    session = create_session!()
    assert {:ok, _reply, socket} = join!(session.id)
    # Ensure :after_join has completed before suspending the Server it queries.
    _ = :sys.get_state(socket.channel_pid)
    server = Server.whereis(session.id)
    :ok = :sys.suspend(server)

    try do
      send(socket.channel_pid, :initial_repaint_timeout)
      _ = :sys.get_state(socket.channel_pid)

      pending = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc

      send(
        socket.channel_pid,
        {:repaint_timeout, pending.repaint_generation, pending.repaint_ref}
      )

      assert_push "replay",
                  %{data: "", reset: false, retrying: true, done: true},
                  2_000

      send(socket.channel_pid, {
        :repaint,
        "INITIAL-AUTHORITY",
        42,
        false,
        pending.repaint_ref
      })

      assert_push "replay",
                  %{data: "SU5JVElBTC1BVVRIT1JJVFk=", seq: 42, reset: true, retrying: false},
                  2_000

      settled = Phoenix.Channel.Server.socket(socket.channel_pid).assigns.fc
      refute settled.skipping
      assert is_nil(settled.repaint_retry_timer)
    after
      if Process.alive?(server), do: :ok = :sys.resume(server)
    end
  end

  test "join on an exited session serves the final screen file" do
    session = create_session!()
    id = to_string(session.id)

    Server.input(session.id, "echo final-words\r")
    Process.sleep(300)

    pid = Server.whereis(id)
    ref = Process.monitor(pid)
    Server.stop(id)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 8_000

    assert {:ok, %{status: :exited}, _socket} = join!(id)
    assert_replay_containing("final-words")
  end

  defp assert_replay_containing(text, expected_history \\ nil, acc \\ "") do
    assert_push "replay", %{data: data, done: done} = payload, 5_000
    if expected_history != nil, do: assert(payload.historyLoaded == expected_history)
    acc = acc <> Base.decode64!(data)

    cond do
      acc =~ text -> :ok
      done -> flunk("replay finished without containing #{inspect(text)}")
      true -> assert_replay_containing(text, expected_history, acc)
    end
  end

  test "cold attach paints the current screen first and loads scrollback on demand" do
    session = create_session!()
    id = to_string(session.id)

    Server.input(
      id,
      "echo OLDEST_MARK; for i in {1..80}; do echo history-$i; done; echo CURRENT_MARK\r"
    )

    Process.sleep(500)

    assert {:ok, _reply, socket} = join!(id)
    # Browser pools report visibility around attach. The new client must not
    # count as an existing viewer and accidentally trigger a full repaint.
    push(socket, "visibility", %{"visible" => true})
    attach!(socket, 8, 80)

    {initial, initial_history} = collect_replay()
    assert initial_history == false
    assert initial =~ "CURRENT_MARK"
    refute initial =~ "OLDEST_MARK"

    push(socket, "load_history", %{})
    {full, full_history} = collect_replay()
    assert full_history == true
    assert full =~ "OLDEST_MARK"
    assert full =~ "CURRENT_MARK"
  end

  test "a dirty hidden viewer can catch up with a viewport-only repaint" do
    session = create_session!()
    id = to_string(session.id)
    Server.input(id, "echo VIEWPORT_CATCH_UP\r")
    Process.sleep(200)

    assert {:ok, _reply, socket} = join!(id)
    attach!(socket, 8, 80)
    {_initial, false} = collect_replay()

    push(socket, "catch_up", %{})
    {repaint, history_loaded} = collect_replay()

    assert history_loaded == false
    assert repaint =~ "VIEWPORT_CATCH_UP"
  end

  test "catch-up pauses output until its viewport repaint arrives" do
    session = create_session!()
    id = to_string(session.id)

    assert {:ok, _reply, socket} = join!(id)
    attach!(socket, 8, 80)
    {_initial, false} = collect_replay()

    # Hold the session server just after the channel queues the repaint. This
    # makes the in-flight window deterministic: output arriving in this
    # window must be dropped rather than racing the snapshot to the client.
    server = Server.whereis(id)
    :ok = :sys.suspend(server)

    try do
      push(socket, "catch_up", %{})
      _ = :sys.get_state(socket.channel_pid)

      channel_socket = Phoenix.Channel.Server.socket(socket.channel_pid)
      assert channel_socket.assigns.fc.skipping
      assert channel_socket.assigns.fc.repaint_requested

      for seq <- 91_001..91_005 do
        DalaWeb.Endpoint.broadcast("terminal:#{id}", "output", %{
          data: Base.encode64("catch-up-race"),
          seq: seq
        })
      end

      _ = :sys.get_state(socket.channel_pid)
      refute_push "output", %{seq: 91_001}, 100
    after
      :ok = :sys.resume(server)
    end

    {_repaint, history_loaded} = collect_replay()
    assert history_loaded == false
  end

  test "viewer visibility is tracked by the terminal server" do
    session = create_session!()
    id = to_string(session.id)
    assert {:ok, _reply, socket} = join!(id)
    attach!(socket)
    collect_replay()

    push(socket, "visibility", %{"visible" => false})
    eventually(fn -> MapSet.size(:sys.get_state(Server.whereis(id)).visible_clients) == 0 end)

    push(socket, "visibility", %{"visible" => true})
    eventually(fn -> MapSet.size(:sys.get_state(Server.whereis(id)).visible_clients) == 1 end)
  end

  defp collect_replay(acc \\ "", history \\ nil) do
    assert_push "replay", %{data: data, done: done, historyLoaded: loaded}, 5_000
    acc = acc <> Base.decode64!(data)
    history = if history == nil, do: loaded, else: history
    assert loaded == history
    if done, do: {acc, history}, else: collect_replay(acc, history)
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  test "join rejects unknown sessions" do
    assert {:error, %{reason: "not_found"}} = join!(Ash.UUID.generate())
  end

  test "join reattaches to the live holder when the server died without cleanup" do
    session = create_session!()
    id = to_string(session.id)
    pid = Server.whereis(id)
    ref = Process.monitor(pid)

    # Let post_init (mark_running + its DB round-trips) finish first: killing
    # the server MID-QUERY drags the sandbox connection down with it, and the
    # next DB call in this test then fails spuriously.
    _ = :sys.get_state(pid)

    # A brutal kill (code-reload purge, crash) skips terminate/2 — but the
    # shell lives in a detached holder, so join must reattach, not bury it.
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    assert {:ok, %{status: :running}, socket} = join!(id)
    assert Server.alive?(id)

    # The reattached shell still works end to end.
    push(socket, "input", %{"data" => "echo reattached-$((3 * 14))\r"})
    assert_output_containing("reattached-42")
  end

  test "join marks the session exited when both server and holder are gone" do
    session = create_session!()
    id = to_string(session.id)
    pid = Server.whereis(id)
    ref = Process.monitor(pid)
    # Same as above: never kill mid-query (see the reattach test).
    _ = :sys.get_state(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}

    # Kill the detached holder too: its shell exits, the holder removes its
    # socket and leaves an exit file behind.
    {:ok, holder} = Dala.Terminal.Holder.connect(id)
    :ok = Dala.Terminal.Holder.send_kill(holder)
    wait_until(fn -> not Dala.Terminal.Holder.exists?(id) end)

    assert {:ok, %{status: :exited}, _socket} = join!(id)
    assert {:ok, %{status: :exited}} = Dala.Terminal.get_session(id)
  end

  test "shell state survives a graceful server stop (dala restart)" do
    session = create_session!()
    id = to_string(session.id)
    assert {:ok, _reply, socket} = join!(id)
    attach!(socket)
    assert_push "replay", %{done: true}

    push(socket, "input", %{"data" => "MARKER=survives-$((10 * 4 + 2))\r"})
    push(socket, "input", %{"data" => "echo set-done\r"})
    assert_output_containing("set-done")

    # Graceful stop = what happens on BEAM shutdown. The holder (and shell)
    # must keep running.
    pid = Server.whereis(id)
    ref = Process.monitor(pid)
    GenServer.stop(pid, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    assert Dala.Terminal.Holder.exists?(id)

    # Reattach (what Boot does on the next startup) and read the state back.
    assert {:ok, _pid} = Server.ensure_started(session)
    assert {:ok, _reply, socket} = join!(id)
    attach!(socket)
    push(socket, "input", %{"data" => "echo got-$MARKER\r"})
    assert_output_containing("got-survives-42")
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  test "input round-trips through the PTY and comes back as output" do
    session = create_session!()
    assert {:ok, _reply, socket} = join!(session.id)
    attach!(socket)
    assert_push "replay", %{done: true}

    push(socket, "input", %{"data" => "echo channel-$((2 * 21))\r"})

    assert_output_containing("channel-42")
  end

  test "resize is accepted" do
    session = create_session!()
    assert {:ok, _reply, socket} = join!(session.id)

    push(socket, "resize", %{"rows" => 40, "cols" => 120})
    push(socket, "input", %{"data" => "tput cols\r"})

    assert_output_containing("120")
  end

  defp assert_output_containing(text, acc \\ "") do
    assert_push "output", %{data: data}, 5_000
    acc = acc <> Base.decode64!(data)

    if acc =~ text do
      :ok
    else
      assert_output_containing(text, acc)
    end
  end
end
