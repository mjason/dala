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
