defmodule Dala.Terminal.SessionTest do
  use Dala.DataCase, async: false

  alias Dala.Terminal.{Scrollback, Server}

  @moduletag :terminal

  defp create_session!(attrs \\ %{}) do
    session = Dala.Terminal.create_session!(Map.merge(%{shell: "/bin/bash"}, attrs))

    on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      Scrollback.clear(session.id)
    end)

    session
  end

  defp await_exit(session_id) do
    ref = Process.monitor(Server.whereis(session_id))
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 8_000
  end

  defp eventually(fun, attempts \\ 40) do
    if fun.() do
      :ok
    else
      if attempts == 0, do: flunk("condition never became true")
      Process.sleep(100)
      eventually(fun, attempts - 1)
    end
  end

  test "create applies defaults and spawns a live shell" do
    session = create_session!()

    assert session.status == :running
    assert session.name == "bash"
    assert session.cwd != nil
    assert session.scrollback_limit == 5_242_880
    assert Server.alive?(session.id)
  end

  test "input reaches the shell; output is broadcast and cached in DETS" do
    session = create_session!()
    Phoenix.PubSub.subscribe(Dala.PubSub, "terminal:#{session.id}")

    Server.input(session.id, "echo dala-$((40 + 2))\r")

    assert_receive %Phoenix.Socket.Broadcast{event: "output"}, 5_000

    eventually(fn ->
      text =
        session.id
        |> Scrollback.replay()
        |> Enum.map_join(&elem(&1, 1))

      text =~ "dala-42"
    end)
  end

  test "close kills the shell and marks the session exited" do
    session = create_session!()

    assert {:ok, true} =
             Ash.run_action(
               Ash.ActionInput.for_action(Dala.Terminal.Session, :close, %{id: session.id})
             )

    await_exit(session.id)

    reloaded = Dala.Terminal.get_session!(session.id)
    assert reloaded.status == :exited
    refute Server.alive?(session.id)
  end

  test "restart revives an exited session and scrollback survives" do
    session = create_session!()
    Server.input(session.id, "echo before-restart\r")

    eventually(fn ->
      Scrollback.replay(session.id) |> Enum.map_join(&elem(&1, 1)) =~ "before-restart"
    end)

    Server.stop(session.id)
    await_exit(session.id)

    assert {:ok, true} =
             Ash.run_action(
               Ash.ActionInput.for_action(Dala.Terminal.Session, :restart, %{id: session.id})
             )

    assert Server.alive?(session.id)
    eventually(fn -> Dala.Terminal.get_session!(session.id).status == :running end)

    # history from before the restart is still replayable
    assert Scrollback.replay(session.id) |> Enum.map_join(&elem(&1, 1)) =~ "before-restart"
  end

  test "shell exit and restart append a terminal mode reset to the stream" do
    session = create_session!()

    # like a TUI enabling SGR mouse tracking, then the shell dying
    Server.input(session.id, "printf '\\e[?1002h\\e[?1006h'\r")
    eventually(fn -> replay_text(session.id) =~ "\e[?1002h" end)

    Server.stop(session.id)
    await_exit(session.id)

    # the exit path must switch mouse reporting back off for future replays
    assert replay_text(session.id) =~ "\e[?1000l\e[?1002l"

    # a fresh PTY attaching to existing scrollback resets modes again
    {:ok, _pid} =
      Ash.run_action(
        Ash.ActionInput.for_action(Dala.Terminal.Session, :restart, %{id: session.id})
      )
      |> then(fn {:ok, true} -> {:ok, Server.whereis(session.id)} end)

    eventually(fn ->
      replay_text(session.id) |> String.split("\e[?1000l") |> length() >= 3
    end)
  end

  defp replay_text(session_id) do
    session_id |> Scrollback.replay() |> Enum.map_join(&elem(&1, 1))
  end

  test "destroy stops the server and clears the scrollback cache" do
    session = create_session!()
    Server.input(session.id, "echo gone\r")

    eventually(fn -> Scrollback.replay(session.id) != [] end)

    pid = Server.whereis(session.id)
    ref = Process.monitor(pid)
    :ok = Dala.Terminal.delete_session!(session)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 8_000

    assert Scrollback.replay(session.id) == []
    assert {:error, _not_found} = Dala.Terminal.get_session(session.id)
  end
end
