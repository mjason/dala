defmodule DalaWeb.TerminalChannelSizeOwnerTest do
  @moduledoc """
  PTY size ownership: each session has at most ONE size owner and only the
  owner's `resize` reaches the PTY. The first client to resize an unowned
  session claims ownership implicitly (a phone alone gets a native narrow
  PTY); everyone else is a follower that renders at the owner's size until
  it takes over explicitly via `claim_size`.
  """
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

  # Channel pushes are async: bounce through the channel process and then the
  # session server so both have handled everything sent so far.
  defp sync!(socket, session_id) do
    _ = :sys.get_state(socket.channel_pid)
    _ = :sys.get_state(Server.whereis(session_id))
  end

  test "join reply carries a client id, current PTY size, and no owner on a fresh session" do
    session = create_session!()

    assert {:ok, reply, _socket} = join!(session.id)
    assert %{client_id: client_id, owner: nil, rows: 24, cols: 80} = reply
    assert is_binary(client_id)
  end

  test "the first resize claims ownership and sizes the PTY" do
    session = create_session!()

    assert {:ok, %{client_id: client_id}, socket} = join!(session.id)
    push(socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(socket, session.id)

    assert Server.viewport(session.id) == {40, 100}
    assert_broadcast "size_owner", %{owner: ^client_id, rows: 40, cols: 100}
  end

  test "a non-owner's resize is ignored silently" do
    session = create_session!()

    assert {:ok, _reply, owner_socket} = join!(session.id)
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)

    assert {:ok, %{owner: owner_id}, follower_socket} = join!(session.id)
    assert is_binary(owner_id)

    push(follower_socket, "resize", %{"rows" => 20, "cols" => 60})
    sync!(follower_socket, session.id)

    assert Server.viewport(session.id) == {40, 100}
  end

  test "the owner's later resizes keep applying" do
    session = create_session!()

    assert {:ok, _reply, socket} = join!(session.id)
    push(socket, "resize", %{"rows" => 40, "cols" => 100})
    push(socket, "resize", %{"rows" => 30, "cols" => 90})
    sync!(socket, session.id)

    assert Server.viewport(session.id) == {30, 90}
  end

  test "claim_size transfers ownership, resizes the PTY, and broadcasts the new owner" do
    session = create_session!()

    assert {:ok, %{client_id: first_id}, first} = join!(session.id)
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)

    assert {:ok, %{client_id: second_id, owner: ^first_id}, second} = join!(session.id)
    push(second, "claim_size", %{"rows" => 21, "cols" => 46})
    sync!(second, session.id)

    assert Server.viewport(session.id) == {21, 46}
    assert_broadcast "size_owner", %{owner: ^second_id, rows: 21, cols: 46}
    assert_broadcast "resize", %{rows: 21, cols: 46}

    # The previous owner is demoted: its resize no longer reaches the PTY.
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)
    assert Server.viewport(session.id) == {21, 46}
  end

  test "owner leaving frees ownership without resizing; the next resize claims" do
    session = create_session!()

    assert {:ok, %{client_id: owner_id}, owner_socket} = join!(session.id)
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)
    assert_broadcast "size_owner", %{owner: ^owner_id}

    assert {:ok, %{client_id: other_id}, other_socket} = join!(session.id)

    Process.unlink(owner_socket.channel_pid)
    _ = leave(owner_socket)

    # Ownership is released and announced; the PTY keeps its size.
    assert_broadcast "size_owner", %{owner: nil, rows: 40, cols: 100}, 2_000
    assert Server.viewport(session.id) == {40, 100}

    # The remaining client's next resize claims ownership.
    push(other_socket, "resize", %{"rows" => 21, "cols" => 46})
    sync!(other_socket, session.id)
    assert Server.viewport(session.id) == {21, 46}
    assert_broadcast "size_owner", %{owner: ^other_id, rows: 21, cols: 46}
  end

  test "claim_size pushes a reset replay snapshot to every attached client" do
    session = create_session!()

    assert {:ok, _reply, first} = join!(session.id)
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)

    assert {:ok, _reply, second} = join!(session.id)
    push(second, "claim_size", %{"rows" => 21, "cols" => 46})
    sync!(second, session.id)

    # The PTY was rewrapped to the new owner's grid: BOTH clients (demoted
    # owner and new owner) must get a fresh snapshot that resets their
    # screens — otherwise the old owner keeps stale wraps on screen.
    assert_push "replay", %{reset: true}, 2_000
    assert_push "replay", %{reset: true}, 2_000
  end

  test "channel clamps degenerate resize dims before they reach the PTY" do
    session = create_session!()

    assert {:ok, _reply, socket} = join!(session.id)
    push(socket, "resize", %{"rows" => 99_999, "cols" => 99_999})
    sync!(socket, session.id)
    assert Server.viewport(session.id) == {500, 1000}

    push(socket, "claim_size", %{"rows" => 0, "cols" => 1})
    sync!(socket, session.id)
    assert Server.viewport(session.id) == {2, 2}
  end

  test "the server clamps dims from any caller, not only the channel" do
    session = create_session!()

    # Start the session server the way a join would.
    assert {:ok, _reply, _socket} = join!(session.id)

    # A 65535×65535 grid is a multi-GB allocation in the holder's emulator —
    # unclamped it aborts the holder and hangs up the PTY under the shell.
    Server.claim_size(session.id, self(), "raw-caller", 65_535, 65_535)
    _ = :sys.get_state(Server.whereis(session.id))
    assert Server.viewport(session.id) == {500, 1000}

    Server.claim_size(session.id, self(), "raw-caller", 1, 1)
    _ = :sys.get_state(Server.whereis(session.id))
    assert Server.viewport(session.id) == {2, 2}
  end

  # A repaint round trip through the holder can chunk into several batches;
  # consume the whole reset replay so later refutes see a clean mailbox.
  defp drain_reset_replay! do
    assert_push "replay", %{reset: true, done: done}, 8_000
    unless done, do: drain_reset_replay!()
  end

  test "after join the channel re-pushes the current ownership (join-gap re-sync)" do
    session = create_session!()

    assert {:ok, %{client_id: owner_id}, owner_socket} = join!(session.id)
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)

    # A size_owner broadcast between the join reply's snapshot and the topic
    # subscription would be lost — the :after_join re-read closes the gap by
    # pushing the authoritative state to the fresh client.
    assert {:ok, _reply, _follower_socket} = join!(session.id)
    assert_push "size_owner", %{owner: ^owner_id, rows: 40, cols: 100}
  end

  test "a non-owner's ignored resize is answered with a corrective size_owner push" do
    session = create_session!()

    assert {:ok, %{client_id: owner_id}, owner_socket} = join!(session.id)
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)

    assert {:ok, _reply, follower_socket} = join!(session.id)
    # Consume the join-time re-sync push so the next match pins the
    # correction itself.
    assert_push "size_owner", %{owner: ^owner_id, rows: 40, cols: 100}

    push(follower_socket, "resize", %{"rows" => 20, "cols" => 60})
    sync!(follower_socket, session.id)

    assert Server.viewport(session.id) == {40, 100}
    assert_push "size_owner", %{owner: ^owner_id, rows: 40, cols: 100}
  end

  test "attach-gap accidental claim: a follower attach after the owner left claims at its dims" do
    session = create_session!()

    assert {:ok, %{client_id: owner_id}, owner_socket} = join!(session.id)
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)
    # The owner's first resize is itself an implicit dim-changing claim
    # (24x80 → 40x100): consume its reset replay so the refute below pins
    # the follower's attach, not this one.
    drain_reset_replay!()

    assert {:ok, %{client_id: follower_id, owner: ^owner_id}, follower_socket} =
             join!(session.id)

    Process.unlink(owner_socket.channel_pid)
    _ = leave(owner_socket)
    assert_broadcast "size_owner", %{owner: nil, rows: 40, cols: 100}, 2_000

    # The follower's attach was prepared while the owner still existed: it
    # reports the OLD owner's dims and — ownership now being free — claims
    # at them (the server cannot tell it from a deliberate first resize).
    push(follower_socket, "attach", %{"rows" => 40, "cols" => 100})
    sync!(follower_socket, session.id)

    assert Server.viewport(session.id) == {40, 100}
    assert_broadcast "size_owner", %{owner: ^follower_id, rows: 40, cols: 100}

    # Dims did not change, so the implicit claim must NOT fan out a reset
    # repaint (join storms would repaint everyone for nothing).
    refute_push "replay", %{reset: true}, 1_500
  end

  test "an implicit re-claim that changes the PTY dims pushes a reset replay" do
    session = create_session!()

    assert {:ok, _reply, owner_socket} = join!(session.id)
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)
    # Consume the first claim's own reset replay (24x80 → 40x100 changed
    # dims) so the assertion below pins the RE-claim's snapshot.
    drain_reset_replay!()

    assert {:ok, _reply, follower_socket} = join!(session.id)
    push(follower_socket, "attach", %{"rows" => 40, "cols" => 100})
    sync!(follower_socket, session.id)

    Process.unlink(owner_socket.channel_pid)
    _ = leave(owner_socket)
    assert_broadcast "size_owner", %{owner: nil}, 2_000

    # The survivor re-fits to its own screen: an implicit claim that CHANGES
    # the dims rewraps the grid, so clients need a fresh snapshot exactly
    # like an explicit claim_size.
    push(follower_socket, "resize", %{"rows" => 30, "cols" => 90})
    sync!(follower_socket, session.id)

    assert Server.viewport(session.id) == {30, 90}
    assert_push "replay", %{reset: true}, 8_000
  end

  test "the owner re-claiming its current dims skips the repaint fan-out" do
    session = create_session!()

    assert {:ok, _reply, socket} = join!(session.id)
    push(socket, "claim_size", %{"rows" => 40, "cols" => 100})
    sync!(socket, session.id)
    # First claim rewraps 24x80 → 40x100: the reset replay is expected.
    drain_reset_replay!()

    push(socket, "claim_size", %{"rows" => 40, "cols" => 100})
    sync!(socket, session.id)
    assert Server.viewport(session.id) == {40, 100}
    refute_push "replay", %{reset: true}, 1_500
  end

  test "join reply reports the current owner and PTY size to late joiners" do
    session = create_session!()

    assert {:ok, %{client_id: owner_id}, owner_socket} = join!(session.id)
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)

    assert {:ok, reply, _socket} = join!(session.id)
    assert %{owner: ^owner_id, rows: 40, cols: 100, client_id: late_id} = reply
    assert late_id != owner_id
  end
end
