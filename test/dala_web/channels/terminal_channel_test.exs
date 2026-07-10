defmodule DalaWeb.TerminalChannelTest do
  use DalaWeb.ChannelCase, async: false

  alias Dala.Terminal.{Holder, Server}

  defp create_session! do
    session = Dala.Terminal.create_session!(%{shell: "/bin/bash"})

    on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      File.rm(Holder.exit_path(to_string(session.id)))
      File.rm(Holder.final_path(to_string(session.id)))
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

    assert_replay_containing("repaint-me-42")
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

  defp assert_replay_containing(text, acc \\ "") do
    assert_push "replay", %{data: data, done: done}, 5_000
    acc = acc <> Base.decode64!(data)

    cond do
      acc =~ text -> :ok
      done -> flunk("replay finished without containing #{inspect(text)}")
      true -> assert_replay_containing(text, acc)
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
