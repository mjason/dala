defmodule Dala.Terminal.ServerPacingTest do
  @moduledoc """
  Two pacing policies protect the session under load. The output batch window
  stays tight for interactive echo but widens while a shell floods, so a redraw
  storm costs a handful of broadcasts instead of hundreds. The cwd poll backs
  off when its own process discovery turns slow — on a saturated box, polling
  harder is what makes it worse.
  """

  use Dala.DataCase, async: false

  alias Dala.Terminal.{Holder, Server}

  @moduletag :terminal

  describe "output batch window" do
    test "starts tight so a keystroke echo pays no batching latency" do
      assert Server.next_out_window(Server.out_window_floor(), false) ==
               Server.out_window_floor()
    end

    test "widens while windows keep closing on coalesced output" do
      floor = Server.out_window_floor()
      wider = Server.next_out_window(floor, true)

      assert wider > floor

      widest =
        Enum.reduce(1..10, floor, fn _step, window -> Server.next_out_window(window, true) end)

      assert widest == Server.out_window_ceiling()
      assert widest <= 25, "a wider window than one render frame would be felt as lag"
    end

    test "snaps back to the floor as soon as a window closes empty" do
      assert Server.next_out_window(Server.out_window_ceiling(), false) ==
               Server.out_window_floor()
    end

    test "a widened window does not outlive the burst that earned it" do
      ceiling = Server.out_window_ceiling()

      assert Server.out_window_after_gap(ceiling, 1) == ceiling
      assert Server.out_window_after_gap(ceiling, 5_000) == Server.out_window_floor()
    end
  end

  describe "cwd poll interval" do
    test "a quick poll keeps the requested cadence" do
      assert Server.next_cwd_poll_interval(2_000, 10) == 2_000
      assert Server.next_cwd_poll_interval(30_000, 10) == 30_000
    end

    test "a slow poll backs off, bounded by the background cadence" do
      backed_off = Server.next_cwd_poll_interval(2_000, 1_500)

      assert backed_off > 2_000
      assert backed_off <= 30_000
      assert Server.next_cwd_poll_interval(30_000, 1_500) == 30_000
    end
  end

  describe "under a live session" do
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

    defp eventually(label, fun, attempts \\ 400) do
      if fun.() do
        :ok
      else
        if attempts == 0, do: flunk("never became true: #{label}")
        Process.sleep(20)
        eventually(label, fun, attempts - 1)
      end
    end

    defp out_window(pid), do: :sys.get_state(pid).out_window

    defp seen?(pid, needle) do
      :sys.get_state(pid).recent_output
      |> Enum.map_join(fn {_seq, data} -> data end)
      |> String.contains?(needle)
    end

    test "a flood widens the window and the next quiet output narrows it again" do
      session = create_session!()
      pid = Server.whereis(session.id)
      eventually("shell is up", fn -> is_integer(:sys.get_state(pid).shell_pid) end)

      assert out_window(pid) == Server.out_window_floor()

      Server.input(session.id, "seq 1 400000; printf 'pacing-done\\n'\n")

      eventually("window widens", fn -> out_window(pid) > Server.out_window_floor() end)

      eventually("window reaches the ceiling", fn ->
        out_window(pid) == Server.out_window_ceiling()
      end)

      eventually("flood finishes", fn -> seen?(pid, "pacing-done") end)

      # Silence retires the width: the next chunk to arrive after it opens an
      # interactive window again, whatever the storm had escalated to.
      Process.sleep(250)
      socket = :sys.get_state(pid).socket
      send(pid, {:tcp, socket, <<Holder.type_output()>> <> "quiet-again"})

      eventually("window returns to the floor", fn ->
        out_window(pid) == Server.out_window_floor()
      end)

      assert seen?(pid, "quiet-again")
    end
  end
end
