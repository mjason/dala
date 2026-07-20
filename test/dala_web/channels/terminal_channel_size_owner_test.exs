defmodule DalaWeb.TerminalChannelSizeOwnerTest do
  @moduledoc """
  PTY size ownership, device-sticky model: each session REMEMBERS the DEVICE
  that owns its size (`size_owner_device`, persisted on the session record).

  - The first device to ever attach/resize adopts an unowned session.
  - Connections from the remembered device silently (re)become the live
    owner — reloads and reconnects stay zero-friction.
  - A DIFFERENT device never auto-claims, even when no live owner exists:
    its resize is ignored and answered with a corrective `size_owner` push.
  - Explicit `claim_size` transfers live ownership AND rewrites the device
    memory.
  - A live owner disconnecting frees the live owner but keeps the memory.
  - Same-device connections (two windows of one browser) may all resize —
    the device is the permission axis; the client axis only matters for
    frontend rendering (soft follower).
  - Clients WITHOUT a device id (legacy bundles) get the old per-connection
    model: live ownership while connected, nothing remembered — nil never
    becomes the device memory.
  - Exited sessions report no owner device, and restart clears the memory.
  """
  use DalaWeb.ChannelCase, async: false

  alias Dala.Terminal.{Holder, Server}

  defp create_session!(extra \\ %{}) do
    session = Dala.Terminal.create_session!(Map.merge(%{shell: "/bin/bash"}, extra))

    on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      File.rm(Holder.exit_path(to_string(session.id)))
      File.rm(Holder.final_path(to_string(session.id)))
      File.rm(Holder.text_final_path(to_string(session.id)))
    end)

    session
  end

  defp join!(session_id, device \\ nil) do
    params = if device, do: %{"device_id" => device}, else: %{}

    DalaWeb.UserSocket
    |> socket(nil, %{})
    |> subscribe_and_join(DalaWeb.TerminalChannel, "terminal:#{session_id}", params)
  end

  # Channel pushes are async: bounce through the channel process and then the
  # session server so both have handled everything sent so far.
  defp sync!(socket, session_id) do
    _ = :sys.get_state(socket.channel_pid)
    _ = :sys.get_state(Server.whereis(session_id))
  end

  test "create with device_id stamps the memory: the creator owns before anyone attaches" do
    # The adoption race this closes: a phone creates a session, and an idle
    # desktop tab auto-mounts it off the session_created broadcast — under
    # first-attach adoption the desktop often WON, locking the phone into
    # following a wide desktop grid. Stamping at creation makes the creating
    # device the remembered owner before any attach can happen.
    session = create_session!(%{device_id: "dev-phone"})
    assert Dala.Terminal.get_session!(session.id).size_owner_device == "dev-phone"

    # The idle desktop attaches FIRST (it wins the race) — and still must
    # not adopt: its viewport report is ignored and answered with a
    # corrective push naming the creator.
    assert {:ok, %{owner: nil, owner_device: "dev-phone"}, desktop} =
             join!(session.id, "dev-desktop")

    # Consume the join-gap re-sync push so the next match pins the correction.
    assert_push "size_owner", %{owner: nil, owner_device: "dev-phone"}

    push(desktop, "attach", %{"rows" => 50, "cols" => 163})
    sync!(desktop, session.id)

    assert Server.viewport(session.id) == {24, 80}
    assert Dala.Terminal.get_session!(session.id).size_owner_device == "dev-phone"
    assert_push "size_owner", %{owner: nil, owner_device: "dev-phone", rows: 24, cols: 80}

    # The creating phone attaches second and its resize applies natively.
    assert {:ok, %{client_id: phone_id}, phone} = join!(session.id, "dev-phone")
    push(phone, "resize", %{"rows" => 40, "cols" => 46})
    sync!(phone, session.id)

    assert Server.viewport(session.id) == {40, 46}
    assert_broadcast "size_owner", %{owner: ^phone_id, owner_device: "dev-phone"}
  end

  test "create without device_id keeps the memory nil — first attach still adopts (fallback)" do
    session = create_session!()
    assert Dala.Terminal.get_session!(session.id).size_owner_device == nil

    assert {:ok, _reply, socket} = join!(session.id, "dev-b")
    push(socket, "resize", %{"rows" => 30, "cols" => 90})
    sync!(socket, session.id)

    assert Server.viewport(session.id) == {30, 90}
    assert Dala.Terminal.get_session!(session.id).size_owner_device == "dev-b"
  end

  test "a blank device_id at creation stamps nothing" do
    # An empty/whitespace device must never become the memory: the channel
    # maps "" to nil on join, so a stamped "" would ghost-lock the session
    # for every real device.
    session = create_session!(%{device_id: "  "})
    assert Dala.Terminal.get_session!(session.id).size_owner_device == nil
  end

  test "join reply carries a client id, current PTY size, and no owner/device on a fresh session" do
    session = create_session!()

    assert {:ok, reply, _socket} = join!(session.id, "dev-a")
    assert %{client_id: client_id, owner: nil, owner_device: nil, rows: 24, cols: 80} = reply
    assert is_binary(client_id)
  end

  test "the first resize ever adopts the device: it sizes the PTY and persists the memory" do
    session = create_session!()

    assert {:ok, %{client_id: client_id}, socket} = join!(session.id, "dev-a")
    push(socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(socket, session.id)

    assert Server.viewport(session.id) == {40, 100}

    assert_broadcast "size_owner", %{
      owner: ^client_id,
      owner_device: "dev-a",
      rows: 40,
      cols: 100
    }

    # The memory survives restarts: it lives on the session record.
    assert Dala.Terminal.get_session!(session.id).size_owner_device == "dev-a"
  end

  test "a different device's resize is ignored silently while the owner is live" do
    session = create_session!()

    assert {:ok, _reply, owner_socket} = join!(session.id, "dev-a")
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)

    assert {:ok, %{owner: owner_id, owner_device: "dev-a"}, follower_socket} =
             join!(session.id, "dev-b")

    assert is_binary(owner_id)

    push(follower_socket, "resize", %{"rows" => 20, "cols" => 60})
    sync!(follower_socket, session.id)

    assert Server.viewport(session.id) == {40, 100}
  end

  test "a different device never auto-claims, even when no live owner exists" do
    session = create_session!()

    assert {:ok, _reply, owner_socket} = join!(session.id, "dev-a")
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)

    Process.unlink(owner_socket.channel_pid)
    _ = leave(owner_socket)
    assert_broadcast "size_owner", %{owner: nil, owner_device: "dev-a"}, 2_000

    assert {:ok, _reply, other_socket} = join!(session.id, "dev-b")
    # Consume the join-time re-sync push so the next match pins the
    # correction itself.
    assert_push "size_owner", %{owner: nil, owner_device: "dev-a"}

    push(other_socket, "resize", %{"rows" => 20, "cols" => 60})
    sync!(other_socket, session.id)

    # The PTY keeps the remembered owner's size; the resize was ignored and
    # answered with a corrective push naming the remembered device.
    assert Server.viewport(session.id) == {40, 100}
    assert_push "size_owner", %{owner: nil, owner_device: "dev-a", rows: 40, cols: 100}
  end

  test "the remembered device silently re-owns on reconnect" do
    session = create_session!()

    assert {:ok, _reply, first} = join!(session.id, "dev-a")
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)

    Process.unlink(first.channel_pid)
    _ = leave(first)
    assert_broadcast "size_owner", %{owner: nil, owner_device: "dev-a"}, 2_000

    # Same device, new connection (a reload): its resize applies without any
    # explicit takeover.
    assert {:ok, %{client_id: second_id}, second} = join!(session.id, "dev-a")
    push(second, "resize", %{"rows" => 30, "cols" => 90})
    sync!(second, session.id)

    assert Server.viewport(session.id) == {30, 90}
    assert_broadcast "size_owner", %{owner: ^second_id, owner_device: "dev-a", rows: 30, cols: 90}
  end

  test "a second connection from the owner device takes the size without friction (reload race)" do
    session = create_session!()

    assert {:ok, _reply, stale} = join!(session.id, "dev-a")
    push(stale, "resize", %{"rows" => 40, "cols" => 100})
    sync!(stale, session.id)

    # The old channel still lingers (reload: the dying socket outlives the
    # new page for a moment) — the same device's fresh connection must not
    # be locked out by it.
    assert {:ok, %{client_id: fresh_id}, fresh} = join!(session.id, "dev-a")
    push(fresh, "resize", %{"rows" => 30, "cols" => 90})
    sync!(fresh, session.id)

    assert Server.viewport(session.id) == {30, 90}
    assert_broadcast "size_owner", %{owner: ^fresh_id, owner_device: "dev-a"}
  end

  test "the owner's later resizes keep applying" do
    session = create_session!()

    assert {:ok, _reply, socket} = join!(session.id, "dev-a")
    push(socket, "resize", %{"rows" => 40, "cols" => 100})
    push(socket, "resize", %{"rows" => 30, "cols" => 90})
    sync!(socket, session.id)

    assert Server.viewport(session.id) == {30, 90}
  end

  test "claim_size transfers ownership, rewrites the device memory, and broadcasts the new owner" do
    session = create_session!()

    assert {:ok, %{client_id: first_id}, first} = join!(session.id, "dev-a")
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)

    assert {:ok, %{client_id: second_id, owner: ^first_id, owner_device: "dev-a"}, second} =
             join!(session.id, "dev-b")

    push(second, "claim_size", %{"rows" => 21, "cols" => 46})
    sync!(second, session.id)

    assert Server.viewport(session.id) == {21, 46}
    assert_broadcast "size_owner", %{owner: ^second_id, owner_device: "dev-b", rows: 21, cols: 46}
    assert_broadcast "resize", %{rows: 21, cols: 46}
    assert Dala.Terminal.get_session!(session.id).size_owner_device == "dev-b"

    # The previous owner is demoted AND its device is forgotten: its resize
    # no longer reaches the PTY.
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)
    assert Server.viewport(session.id) == {21, 46}
  end

  test "after claim_size the new device re-owns across reconnects" do
    session = create_session!()

    assert {:ok, _reply, first} = join!(session.id, "dev-a")
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)

    assert {:ok, _reply, second} = join!(session.id, "dev-b")
    push(second, "claim_size", %{"rows" => 21, "cols" => 46})
    sync!(second, session.id)

    Process.unlink(second.channel_pid)
    _ = leave(second)
    assert_broadcast "size_owner", %{owner: nil, owner_device: "dev-b"}, 2_000

    assert {:ok, _reply, back} = join!(session.id, "dev-b")
    push(back, "resize", %{"rows" => 22, "cols" => 48})
    sync!(back, session.id)

    assert Server.viewport(session.id) == {22, 48}
  end

  test "owner leaving frees the live owner but keeps the device memory and the PTY size" do
    session = create_session!()

    assert {:ok, %{client_id: owner_id}, owner_socket} = join!(session.id, "dev-a")
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)
    assert_broadcast "size_owner", %{owner: ^owner_id, owner_device: "dev-a"}

    Process.unlink(owner_socket.channel_pid)
    _ = leave(owner_socket)

    # Live ownership is released and announced; the memory and PTY size stay.
    assert_broadcast "size_owner",
                     %{owner: nil, owner_device: "dev-a", rows: 40, cols: 100},
                     2_000

    assert Server.viewport(session.id) == {40, 100}
    assert Dala.Terminal.get_session!(session.id).size_owner_device == "dev-a"
  end

  test "a no-device join drives the size while connected, but nothing is ever remembered" do
    session = create_session!()

    # Legacy clients that never send device_id get the old per-connection
    # model: the first resize with free ownership makes them the LIVE owner,
    # with a nil owner device — nil must never be adopted into the memory.
    assert {:ok, %{client_id: legacy_id}, legacy} = join!(session.id)
    push(legacy, "resize", %{"rows" => 40, "cols" => 100})
    sync!(legacy, session.id)
    assert Server.viewport(session.id) == {40, 100}
    assert_broadcast "size_owner", %{owner: ^legacy_id, owner_device: nil}
    assert Dala.Terminal.get_session!(session.id).size_owner_device == nil

    # While that owner is LIVE, another deviceless connection cannot steal
    # the size (the old model's rule).
    assert {:ok, _reply, other} = join!(session.id)
    push(other, "resize", %{"rows" => 20, "cols" => 60})
    sync!(other, session.id)
    assert Server.viewport(session.id) == {40, 100}
  end

  test "a no-device owner leaving does not ghost-lock the session for the next client" do
    session = create_session!()

    assert {:ok, _reply, legacy} = join!(session.id)
    push(legacy, "resize", %{"rows" => 40, "cols" => 100})
    sync!(legacy, session.id)

    Process.unlink(legacy.channel_pid)
    _ = leave(legacy)
    assert_broadcast "size_owner", %{owner: nil, owner_device: nil}, 2_000

    # Under the buggy fallback (device := client_id) the dead connection's
    # id would be REMEMBERED and every later client locked into follower
    # mode forever. With a nil device nothing persists: the next client —
    # here a real device — adopts freely.
    assert {:ok, %{owner: nil, owner_device: nil}, fresh} = join!(session.id, "dev-b")
    push(fresh, "resize", %{"rows" => 30, "cols" => 90})
    sync!(fresh, session.id)

    assert Server.viewport(session.id) == {30, 90}
    assert Dala.Terminal.get_session!(session.id).size_owner_device == "dev-b"
  end

  test "an empty-string device id behaves exactly like a missing one" do
    session = create_session!()

    assert {:ok, %{client_id: blank_id}, blank} = join!(session.id, "")
    push(blank, "resize", %{"rows" => 40, "cols" => 100})
    sync!(blank, session.id)
    assert Server.viewport(session.id) == {40, 100}
    assert_broadcast "size_owner", %{owner: ^blank_id, owner_device: nil}
    assert Dala.Terminal.get_session!(session.id).size_owner_device == nil

    Process.unlink(blank.channel_pid)
    _ = leave(blank)
    assert_broadcast "size_owner", %{owner: nil, owner_device: nil}, 2_000

    assert {:ok, _reply, next} = join!(session.id)
    push(next, "resize", %{"rows" => 20, "cols" => 60})
    sync!(next, session.id)
    assert Server.viewport(session.id) == {20, 60}
  end

  test "a no-device resize never steals from a remembered device" do
    session = create_session!()

    assert {:ok, _reply, owner_socket} = join!(session.id, "dev-a")
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)

    Process.unlink(owner_socket.channel_pid)
    _ = leave(owner_socket)
    assert_broadcast "size_owner", %{owner: nil, owner_device: "dev-a"}, 2_000

    # No live owner, but the memory guards the size: the legacy client's
    # resize is ignored and answered with a corrective push.
    assert {:ok, _reply, legacy} = join!(session.id)
    assert_push "size_owner", %{owner: nil, owner_device: "dev-a"}

    push(legacy, "resize", %{"rows" => 20, "cols" => 60})
    sync!(legacy, session.id)

    assert Server.viewport(session.id) == {40, 100}
    assert_push "size_owner", %{owner: nil, owner_device: "dev-a", rows: 40, cols: 100}
  end

  test "claim_size pushes a reset replay snapshot to every attached client" do
    session = create_session!()

    assert {:ok, _reply, first} = join!(session.id, "dev-a")
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)

    assert {:ok, _reply, second} = join!(session.id, "dev-b")
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

    assert {:ok, _reply, socket} = join!(session.id, "dev-a")
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
    assert {:ok, _reply, _socket} = join!(session.id, "dev-a")

    # A 65535×65535 grid is a multi-GB allocation in the holder's emulator —
    # unclamped it aborts the holder and hangs up the PTY under the shell.
    Server.claim_size(session.id, self(), "raw-caller", "raw-device", 65_535, 65_535)
    _ = :sys.get_state(Server.whereis(session.id))
    assert Server.viewport(session.id) == {500, 1000}

    Server.claim_size(session.id, self(), "raw-caller", "raw-device", 1, 1)
    _ = :sys.get_state(Server.whereis(session.id))
    assert Server.viewport(session.id) == {2, 2}
  end

  # A repaint round trip through the holder can chunk into several batches;
  # consume the whole reset replay so later refutes see a clean mailbox.
  defp drain_reset_replay! do
    assert_push "replay", %{reset: true, done: done}, 8_000
    unless done, do: drain_reset_replay!()
  end

  defp drain_replay! do
    assert_push "replay", %{done: done}, 8_000
    unless done, do: drain_replay!()
  end

  test "after join the channel re-pushes the current ownership (join-gap re-sync)" do
    session = create_session!()

    assert {:ok, %{client_id: owner_id}, owner_socket} = join!(session.id, "dev-a")
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)

    # A size_owner broadcast between the join reply's snapshot and the topic
    # subscription would be lost — the :after_join re-read closes the gap by
    # pushing the authoritative state to the fresh client.
    assert {:ok, _reply, _follower_socket} = join!(session.id, "dev-b")
    assert_push "size_owner", %{owner: ^owner_id, owner_device: "dev-a", rows: 40, cols: 100}
  end

  test "a non-owner's ignored resize is answered with a corrective size_owner push" do
    session = create_session!()

    assert {:ok, %{client_id: owner_id}, owner_socket} = join!(session.id, "dev-a")
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)

    assert {:ok, _reply, follower_socket} = join!(session.id, "dev-b")
    # Consume the join-time re-sync push so the next match pins the
    # correction itself.
    assert_push "size_owner", %{owner: ^owner_id, owner_device: "dev-a", rows: 40, cols: 100}

    push(follower_socket, "resize", %{"rows" => 20, "cols" => 60})
    sync!(follower_socket, session.id)

    assert Server.viewport(session.id) == {40, 100}
    assert_push "size_owner", %{owner: ^owner_id, owner_device: "dev-a", rows: 40, cols: 100}
  end

  test "a different device's attach after the owner left does not claim (no attach-gap steal)" do
    session = create_session!()

    assert {:ok, %{client_id: owner_id}, owner_socket} = join!(session.id, "dev-a")
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)
    drain_reset_replay!()

    assert {:ok, %{owner: ^owner_id}, follower_socket} = join!(session.id, "dev-b")

    Process.unlink(owner_socket.channel_pid)
    _ = leave(owner_socket)
    assert_broadcast "size_owner", %{owner: nil, owner_device: "dev-a"}, 2_000

    # Under the old model this attach would have auto-claimed the freed
    # ownership. Now the memory protects it: the attach is ignored and the
    # phone/follower keeps rendering at the remembered size.
    push(follower_socket, "attach", %{"rows" => 40, "cols" => 100})
    sync!(follower_socket, session.id)

    assert Server.viewport(session.id) == {40, 100}
    assert Dala.Terminal.get_session!(session.id).size_owner_device == "dev-a"
    refute_broadcast "size_owner", %{owner_device: "dev-b"}, 1_000
  end

  test "a same-device re-claim that changes the PTY dims pushes a reset replay" do
    session = create_session!()

    assert {:ok, _reply, first} = join!(session.id, "dev-a")
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)
    # Consume the first claim's own reset replay (24x80 → 40x100 changed
    # dims) so the assertion below pins the RE-claim's snapshot.
    drain_reset_replay!()

    Process.unlink(first.channel_pid)
    _ = leave(first)
    assert_broadcast "size_owner", %{owner: nil, owner_device: "dev-a"}, 2_000

    # The remembered device reconnects at different dims: the silent re-own
    # rewraps the grid, so clients need a fresh snapshot exactly like an
    # explicit claim_size.
    assert {:ok, _reply, second} = join!(session.id, "dev-a")
    push(second, "resize", %{"rows" => 30, "cols" => 90})
    sync!(second, session.id)

    assert Server.viewport(session.id) == {30, 90}
    assert_push "replay", %{reset: true}, 8_000
  end

  test "an initial attach that resizes a shared PTY repaints existing viewers" do
    session = create_session!()

    assert {:ok, _reply, owner} = join!(session.id, "dev-a")
    push(owner, "attach", %{"rows" => 40, "cols" => 100})
    sync!(owner, session.id)
    drain_replay!()

    assert {:ok, _reply, follower} = join!(session.id, "dev-b")
    push(follower, "attach", %{"rows" => 40, "cols" => 100})
    sync!(follower, session.id)
    drain_replay!()

    # A new window from the remembered owner device can re-own during its
    # initial attach. Because the follower already renders the old grid, the
    # optimization must retain the all-client full repaint in this case.
    assert {:ok, _reply, reconnect} = join!(session.id, "dev-a")
    push(reconnect, "attach", %{"rows" => 30, "cols" => 90})
    sync!(reconnect, session.id)

    assert Server.viewport(session.id) == {30, 90}
    assert_push "replay", %{reset: true, historyLoaded: true}, 8_000
  end

  test "a same-device re-claim at the current dims skips the repaint fan-out" do
    session = create_session!()

    assert {:ok, _reply, first} = join!(session.id, "dev-a")
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)
    drain_reset_replay!()

    Process.unlink(first.channel_pid)
    _ = leave(first)
    assert_broadcast "size_owner", %{owner: nil, owner_device: "dev-a"}, 2_000

    # Reload at the same dims: nothing rewrapped, no repaint storm.
    assert {:ok, _reply, second} = join!(session.id, "dev-a")
    push(second, "attach", %{"rows" => 40, "cols" => 100})
    sync!(second, session.id)

    assert Server.viewport(session.id) == {40, 100}
    refute_push "replay", %{reset: true}, 1_500
  end

  test "the owner re-claiming its current dims skips the repaint fan-out" do
    session = create_session!()

    assert {:ok, _reply, socket} = join!(session.id, "dev-a")
    push(socket, "claim_size", %{"rows" => 40, "cols" => 100})
    sync!(socket, session.id)
    # First claim rewraps 24x80 → 40x100: the reset replay is expected.
    drain_reset_replay!()

    push(socket, "claim_size", %{"rows" => 40, "cols" => 100})
    sync!(socket, session.id)
    assert Server.viewport(session.id) == {40, 100}
    refute_push "replay", %{reset: true}, 1_500
  end

  # Flush every pending replay push (fan-outs from BOTH joined sockets can
  # interleave), considering the stream settled after a quiet window.
  defp settle_replays! do
    receive do
      %Phoenix.Socket.Message{event: "replay"} -> settle_replays!()
    after
      1_500 -> :ok
    end
  end

  test "same-device windows: every resize applies, ownership flips, repaints only on dims change" do
    session = create_session!()

    assert {:ok, %{client_id: first_id}, first} = join!(session.id, "dev-a")
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)
    assert Server.viewport(session.id) == {40, 100}
    assert_broadcast "size_owner", %{owner: ^first_id, owner_device: "dev-a"}

    # A second window of the SAME device (two browser windows, one
    # localStorage) joins and resizes: the device is the PERMISSION axis,
    # so the server applies it and live ownership flips to the new window.
    assert {:ok, %{client_id: second_id, owner: ^first_id, owner_device: "dev-a"}, second} =
             join!(session.id, "dev-a")

    push(second, "resize", %{"rows" => 30, "cols" => 90})
    sync!(second, session.id)
    assert Server.viewport(session.id) == {30, 90}
    # The first window receives this broadcast and (client-side) demotes to
    # SOFT follower: it stops pushing its own fit, which is what bounds the
    # ping-pong — each window only pushes on a LOCAL fit change or explicit
    # refit, never in reaction to a broadcast.
    assert_broadcast "size_owner", %{owner: ^second_id, owner_device: "dev-a", rows: 30, cols: 90}

    # The thrash scenario the soft-follower role exists for: the OLD window
    # resizes again after the takeover (e.g. its fit changed while it was
    # still driving). Server semantics are unchanged — same device, so it
    # applies and ownership flips back; every attached client is told.
    push(first, "resize", %{"rows" => 40, "cols" => 100})
    sync!(first, session.id)
    assert Server.viewport(session.id) == {40, 100}
    assert_broadcast "size_owner", %{owner: ^first_id, owner_device: "dev-a", rows: 40, cols: 100}

    # Repaint fan-outs so far were justified: the dims changed. A flip at
    # the CURRENT dims stays quiet — no repaint storm from mere ownership
    # churn.
    settle_replays!()
    push(second, "resize", %{"rows" => 40, "cols" => 100})
    sync!(second, session.id)
    assert Server.viewport(session.id) == {40, 100}
    assert_broadcast "size_owner", %{owner: ^second_id, owner_device: "dev-a"}
    refute_push "replay", %{reset: true}, 1_500
  end

  test "joining an exited session reports no owner device — nothing to follow or take over" do
    # Seeded directly: no shell, no server — the join serves the final
    # screen instead of a live PTY.
    session =
      Ash.Seed.seed!(Dala.Terminal.Session, %{
        name: "gone",
        shell: "/bin/bash",
        cwd: "/tmp",
        status: :exited,
        exit_code: 0,
        size_owner_device: "dev-a",
        position: 1.0
      })

    # Even the remembered owner device is withheld: a follower banner over a
    # dead terminal would offer a takeover of nothing (and a restart clears
    # the memory anyway).
    assert {:ok, reply, _socket} = join!(session.id, "dev-b")
    assert %{status: :exited, owner: nil, owner_device: nil} = reply
  end

  test "restart clears the size-owner memory so the restarting device adopts fresh" do
    session = create_session!()

    assert {:ok, _reply, socket} = join!(session.id, "dev-a")
    push(socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(socket, session.id)
    assert Dala.Terminal.get_session!(session.id).size_owner_device == "dev-a"

    # Kill the shell, then restart the session through the restart action.
    Server.shutdown_and_wait(session.id)

    Dala.Terminal.Session
    |> Ash.ActionInput.for_action(:restart, %{id: session.id})
    |> Ash.run_action!()

    # The memory is gone: whatever device attaches to the fresh shell first
    # adopts it, instead of dev-a locking followers onto a PTY it may never
    # attach to again.
    assert Dala.Terminal.get_session!(session.id).size_owner_device == nil

    assert {:ok, %{owner_device: nil}, fresh} = join!(session.id, "dev-b")
    push(fresh, "resize", %{"rows" => 30, "cols" => 90})
    sync!(fresh, session.id)
    assert Server.viewport(session.id) == {30, 90}
    assert Dala.Terminal.get_session!(session.id).size_owner_device == "dev-b"
  end

  test "join reply reports the current owner, device, and PTY size to late joiners" do
    session = create_session!()

    assert {:ok, %{client_id: owner_id}, owner_socket} = join!(session.id, "dev-a")
    push(owner_socket, "resize", %{"rows" => 40, "cols" => 100})
    sync!(owner_socket, session.id)

    assert {:ok, reply, _socket} = join!(session.id, "dev-b")

    assert %{owner: ^owner_id, owner_device: "dev-a", rows: 40, cols: 100, client_id: late_id} =
             reply

    assert late_id != owner_id
  end
end
