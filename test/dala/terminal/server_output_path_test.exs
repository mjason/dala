defmodule Dala.Terminal.ServerOutputPathTest do
  @moduledoc """
  The output path is the session's hot loop: every byte a shell prints passes
  through `Dala.Terminal.Server`, the same process that has to answer
  keystrokes, resize and repaint. Plain-text extraction exists ONLY for MCP
  `wait(match:)`, so it must not be spent on the common case where nobody is
  waiting — while still matching exactly as before once a waiter exists.
  """

  use Dala.TerminalCase, async: false

  # Frames as the holder would deliver them, so batching, seq bookkeeping and
  # retention all run exactly as in production.
  defp feed(pid, chunks) do
    socket = :sys.get_state(pid).socket

    Enum.each(chunks, fn chunk -> send(pid, {:tcp, socket, <<Holder.type_output()>> <> chunk}) end)

    # Let the 5ms output batch window close.
    _ = :sys.get_state(pid)
    Process.sleep(30)
    _ = :sys.get_state(pid)
  end

  test "output is retained raw, so no chunk pays for plain-text extraction" do
    session = create_session!()
    pid = Server.whereis(session.id)

    feed(pid, ["\e[31mred\e[0m plain-tail"])

    eventually(fn -> retained_output(pid) =~ "plain-tail" end)

    buffer = retained_output(pid)

    assert String.contains?(buffer, "\e[31m"),
           "recent_output must keep the raw bytes; filtering every chunk is the hot-path cost " <>
             "this retention exists to avoid"

    assert :sys.get_state(pid).match_filter_state == :text
  end

  test "a wait registered after the output still matches across chunk and escape boundaries" do
    session = create_session!()
    pid = Server.whereis(session.id)

    {:ok, before_seq} = Server.current_seq(session.id)

    # The needle is split across frames AND interrupted by styling: the match
    # must see the reassembled plain text, not the raw stream.
    feed(pid, ["\e[32mnee", "d", "le\e[0m done"])

    assert {:ok, %{reason: "match", match: "needle"}} =
             Server.wait(session.id, before_seq, match: "needle", timeout: 500)
  end

  test "a live waiter is woken by a needle that arrives split across later frames" do
    session = create_session!()
    pid = Server.whereis(session.id)

    {:ok, before_seq} = Server.current_seq(session.id)
    parent = self()

    spawn_link(fn ->
      send(
        parent,
        {:waited, Server.wait(session.id, before_seq, match: "late-needle", timeout: 4_000)}
      )
    end)

    eventually(fn -> map_size(:sys.get_state(pid).waiters) > 0 end)

    feed(pid, ["\e[1mlate-", "nee", "dle\e[0m"])

    assert_receive {:waited, {:ok, %{reason: "match", match: "late-needle"}}}, 5_000
  end

  test "an escape sequence straddling frames never leaks into a waiter's match text" do
    session = create_session!()
    pid = Server.whereis(session.id)

    {:ok, before_seq} = Server.current_seq(session.id)
    parent = self()

    spawn_link(fn ->
      send(
        parent,
        {:waited, Server.wait(session.id, before_seq, match: "ab", timeout: 1_000)}
      )
    end)

    eventually(fn -> map_size(:sys.get_state(pid).waiters) > 0 end)

    # Raw bytes contain "a\e[31mb": only "ab" after filtering, and the CSI
    # parameters ("31m") must never become matchable text.
    feed(pid, ["a\e[3", "1mb"])

    assert_receive {:waited, {:ok, %{reason: "match", match: "ab"}}}, 2_000

    {:ok, seq} = Server.current_seq(session.id)

    assert {:ok, %{reason: "timeout"}} =
             Server.wait(session.id, seq, match: "31m", timeout: 150)
  end

  test "plain output still wakes waiters that ask for any output" do
    session = create_session!()
    pid = Server.whereis(session.id)

    {:ok, before_seq} = Server.current_seq(session.id)

    feed(pid, ["some output"])

    assert {:ok, %{reason: "output"}} =
             Server.wait(session.id, before_seq, events: ["output"], timeout: 500)
  end
end
