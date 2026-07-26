defmodule Dala.Terminal.ServerFloodTest do
  @moduledoc """
  A shell can produce output far faster than this server can broadcast it. With
  an unbounded delivery window the socket driver pours every frame into the
  mailbox, so a keystroke lands behind megabytes of backlog — the "typing goes
  dead while the build runs" failure. The backlog belongs in the holder's
  bounded ring (which drops old bytes and repairs clients from its emulator),
  not in this process's mailbox.
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

  defp eventually(fun, attempts \\ 400) do
    if fun.() do
      :ok
    else
      if attempts == 0, do: flunk("condition never became true")
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp seen?(pid, needle) do
    :sys.get_state(pid).recent_output
    |> Enum.map_join(fn {_seq, data} -> data end)
    |> String.contains?(needle)
  end

  test "the holder socket is armed with a bounded window" do
    session = create_session!()
    pid = Server.whereis(session.id)

    assert {:ok, [active: active]} = :inet.getopts(:sys.get_state(pid).socket, [:active])

    assert is_integer(active) and active > 0 and active <= 64,
           "expected a bounded delivery window, got active: #{inspect(active)} — " <>
             "an unbounded one lets a flooding shell grow this server's mailbox without limit"
  end

  test "a flood cannot pile up in the mailbox while the server is not draining it" do
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    Server.input(session.id, "seq 1 400000; printf 'flood-done\\n'\n")

    # Suspended, the server processes nothing — but the socket driver keeps
    # delivering. Whatever the window allows is all the mailbox may ever hold.
    :sys.suspend(pid)
    Process.sleep(400)
    {:message_queue_len, queued} = Process.info(pid, :message_queue_len)
    :sys.resume(pid)

    assert queued <= 32,
           "#{queued} frames were queued in the mailbox while the server was not draining it; " <>
             "the delivery window is not bounding the backlog"

    # The window must re-arm on its own, or the session goes silent forever
    # after the first burst.
    eventually(fn -> seen?(pid, "flood-done") end)
  end

  test "input still reaches the shell while it floods its PTY" do
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    Server.input(session.id, "seq 1 400000\n")
    Server.input(session.id, "printf 'typed-through-flood\\n'\n")

    eventually(fn -> seen?(pid, "typed-through-flood") end)
    assert Dala.Terminal.get_session!(session.id).status == :running

    # The window must be wide enough that ordinary flooding never stalls the
    # holder's writer into its two-second timeout: a reattach mid-build costs
    # every client a full repaint.
    assert :sys.get_state(pid).reconnects == 0
  end
end
