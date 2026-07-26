defmodule Dala.Terminal.ServerReconnectTest do
  @moduledoc """
  The holder hangs up on a client whose socket write blocks for two seconds —
  which is exactly what a saturated machine does to this server. Losing the
  connection is NOT proof that the shell died: as long as the holder is still
  listening and left no exit status behind, the session must reattach instead
  of being buried as "exited" with a live shell behind it.
  """

  use Dala.DataCase, async: false

  alias Dala.Terminal.{Holder, Server}

  @moduletag :terminal

  defp create_session!(attrs \\ %{}) do
    session = Dala.Terminal.create_session!(Map.merge(%{shell: "/bin/bash"}, attrs))

    on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      id = to_string(session.id)
      File.rm(Holder.exit_path(id))
      File.rm(Holder.final_path(id))
      File.rm(Holder.text_final_path(id))
      File.rm(Holder.socket_path(id) <> ".log")
    end)

    session
  end

  defp eventually(fun, attempts \\ 200) do
    if fun.() do
      :ok
    else
      if attempts == 0, do: flunk("condition never became true")
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp status(session), do: Dala.Terminal.get_session!(session.id).status

  test "a detach with a live holder and no exit status reattaches the session" do
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    old_socket = :sys.get_state(pid).socket
    Server.attach(session.id, self(), "reconnect-test", "device-a", 30, 100)

    # Exactly what the holder's write timeout produces on this side.
    send(pid, {:tcp_closed, old_socket})

    eventually(fn ->
      state = :sys.get_state(pid)
      state.socket != nil and state.socket != old_socket
    end)

    assert Process.alive?(pid)
    assert status(session) == :running

    # The holder greets every new connection, so the shell identity and the
    # PTY size this server owns are re-established.
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)
    assert :sys.get_state(pid).size == {30, 100}

    # The reattached holder cleared its transit queue, so whatever it dropped
    # in between has to be repaired from the emulator.
    assert_receive {:repaint_reset, _data, _seq, _history_loaded}, 5_000

    # The reattached socket is live: input still reaches the shell and output
    # still comes back.
    Server.input(session.id, "printf 'reattached-ok\\n'\n")

    eventually(fn ->
      :sys.get_state(pid).recent_output
      |> Enum.map_join(fn {_seq, data} -> data end)
      |> String.contains?("reattached-ok")
    end)
  end

  test "in-flight repaint and snapshot requests are settled by a reattach" do
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    socket = :sys.get_state(pid).socket
    # replace_state runs INSIDE the server, so the requester has to be captured
    # out here or the server ends up answering itself.
    caller = self()

    # Queue requests whose answers can only ever come from the OLD connection.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | pending_repaints: :queue.in({caller, 0, make_ref()}, state.pending_repaints),
          pending_text_snapshots:
            :queue.in({:caller, {caller, make_ref()}}, state.pending_text_snapshots)
      }
    end)

    send(pid, {:tcp_closed, socket})

    eventually(fn ->
      state = :sys.get_state(pid)
      state.socket != nil and state.socket != socket
    end)

    # A channel must never be left waiting on a dead connection's FIFO slot.
    assert_receive {:repaint, "", _seq, false, _ref}, 5_000

    eventually(fn -> :queue.len(:sys.get_state(pid).pending_text_snapshots) == 0 end)
  end

  test "a shell that really exited still marks the session exited" do
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    socket = :sys.get_state(pid).socket
    ref = Process.monitor(pid)

    # The holder writes this file when the shell dies while no client is
    # attached; it is the authoritative "the shell is gone" signal.
    File.write!(Holder.exit_path(to_string(session.id)), "3")
    send(pid, {:tcp_closed, socket})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    assert status(session) == :exited
    assert Dala.Terminal.get_session!(session.id).exit_code == 3
  end

  test "a holder that is gone for good marks the session exited" do
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    state = :sys.get_state(pid)
    shell_pid = state.shell_pid
    on_exit(fn -> System.cmd("kill", ["-KILL", to_string(shell_pid)], stderr_to_stdout: true) end)

    # No listening socket and no exit status: nothing left to reattach to.
    File.rm(Holder.socket_path(to_string(session.id)))
    ref = Process.monitor(pid)
    send(pid, {:tcp_closed, state.socket})

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    assert status(session) == :exited
  end

  test "a holder that keeps hanging up stops the reattach loop instead of spinning" do
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    ref = Process.monitor(pid)

    # Every detach reattaches successfully and is immediately followed by
    # another one: without a bound this is a livelock.
    Enum.each(1..12, fn _attempt ->
      case Server.whereis(session.id) do
        nil ->
          :ok

        alive ->
          socket = :sys.get_state(alive).socket
          send(alive, {:tcp_closed, socket})
          Process.sleep(30)
      end
    end)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 10_000
    assert status(session) == :exited
  end
end
