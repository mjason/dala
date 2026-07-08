defmodule DalaWeb.TerminalChannelTest do
  use DalaWeb.ChannelCase, async: false

  alias Dala.Terminal.{Scrollback, Server}

  defp create_session! do
    session = Dala.Terminal.create_session!(%{shell: "/bin/bash"})

    on_exit(fn ->
      Server.shutdown_and_wait(session.id)
      Scrollback.clear(session.id)
    end)

    session
  end

  defp join!(session_id) do
    DalaWeb.UserSocket
    |> socket(nil, %{})
    |> subscribe_and_join(DalaWeb.TerminalChannel, "terminal:#{session_id}")
  end

  test "join replays the scrollback cache and reports status" do
    session = create_session!()
    Scrollback.append(session.id, "cached-output")

    assert {:ok, %{status: :running}, _socket} = join!(session.id)

    assert_push "replay", %{data: data, done: true}
    assert Base.decode64!(data) =~ "cached-output"
  end

  test "join rejects unknown sessions" do
    assert {:error, %{reason: "not_found"}} = join!(Ash.UUID.generate())
  end

  test "input round-trips through the PTY and comes back as output" do
    session = create_session!()
    assert {:ok, _reply, socket} = join!(session.id)
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
