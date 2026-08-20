defmodule Dala.Terminal.ServerFloodTest do
  @moduledoc """
  A shell can produce output far faster than this server can broadcast it. With
  an unbounded delivery window the socket driver pours every frame into the
  mailbox, so a keystroke lands behind megabytes of backlog — the "typing goes
  dead while the build runs" failure. The backlog belongs in the holder's
  bounded ring (which drops old bytes and repairs clients from its emulator),
  not in this process's mailbox.
  """

  use Dala.TerminalCase, async: false

  @flood_lines if(Dala.Platform.windows?(), do: 100_000, else: 400_000)

  test "the holder socket is armed with a bounded window" do
    session = create_session!()
    pid = Server.whereis(session.id)

    assert {:ok, [active: active]} = :inet.getopts(:sys.get_state(pid).socket, [:active])

    # The option is a countdown, so it sits at or below the configured window.
    assert is_integer(active) and active > 0 and active <= Holder.active_frames(),
           "expected the bounded delivery window, got active: #{inspect(active)} — " <>
             "an unbounded one lets a flooding shell grow this server's mailbox without limit"
  end

  test "a flood cannot pile up in the mailbox while the server is not draining it" do
    session = create_session!()
    pid = Server.whereis(session.id)
    eventually(fn -> is_integer(:sys.get_state(pid).shell_pid) end)

    Server.input(session.id, "seq 1 #{@flood_lines}; printf 'flood-done\\n'\r")
    # Suspending before the shell has started writing would measure nothing.
    eventually("flood is flowing", fn -> :sys.get_state(pid).seq > 0 end)

    # Suspended, the server processes nothing — but the socket driver keeps
    # delivering. Whatever the window allows is all the mailbox may ever hold.
    :sys.suspend(pid)
    Process.sleep(50)
    {:message_queue_len, queued} = Process.info(pid, :message_queue_len)
    :sys.resume(pid)

    assert queued <= Holder.active_frames() * 2,
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
    {:ok, baseline} = Server.current_seq(session.id)

    Server.input(session.id, "while :; do printf 'flooding-output\\n'; done &\r")
    eventually("background flood is flowing", fn -> seen?(pid, "flooding-output") end)
    Server.input(session.id, "kill $!; printf 'typed-through-flood\\n'\r")

    assert {:ok, %{reason: "match", match: "typed-through-flood"}} =
             Server.wait(session.id, baseline, timeout: 15_000, match: "typed-through-flood")

    assert Dala.Terminal.get_session!(session.id).status == :running

    # The window must be wide enough that ordinary flooding never stalls the
    # holder's writer into its two-second timeout: a reattach mid-build costs
    # every client a full repaint.
    assert :sys.get_state(pid).reconnects == 0
  end
end
