defmodule Dala.Terminal.RenderModeTest do
  @moduledoc """
  Render mode is zellij's model: while an application owns the ALTERNATE
  screen the holder stops forwarding its bytes and sends diffed frames on a
  10ms tick instead, so what reaches a browser is proportional to what
  CHANGED rather than to what the program WROTE.

  These drive a real shell through a real holder, because the property only
  exists end to end — the diffing lives in Rust, the handover in the holder's
  PTY reader, and the bytes arrive here through the same socket a browser is
  fed from.

  Every literal these tests look for is ASSEMBLED BY THE SHELL (`V=STE;
  echo "$V"ADY`). A plain `echo STEADY` puts the word in the terminal twice —
  once when bash echoes the command line you typed, once when it runs — and
  the first copy lands before a single byte of the script has executed. Both
  the "did it finish" waits and the paint counting below would then be
  measuring bash's line editor instead of the holder.
  """

  use Dala.TerminalCase, async: false

  @repaints 300

  # Split so neither half appears joined in the echoed command line.
  defp split_literal(word) do
    {head, tail} = String.split_at(word, div(String.length(word), 2))
    {"V=#{head}; ", ~s|"$V"#{tail}|}
  end

  defp shell(session, command), do: Server.input(session.id, command <> "\n")

  defp ready!(pid) do
    eventually("shell prompt is up", fn -> retained_output(pid) != "" end)
  end

  # Runs `script`, then prints a marker AFTER the alternate screen has been
  # left, so waiting for it means the whole thing has actually run.
  defp run_and_await(session, pid, script, marker) do
    {assign, expr} = split_literal(marker)
    shell(session, assign <> script <> "; echo " <> expr)
    eventually("script finished (#{marker})", fn -> seen?(pid, marker) end)
    _ = :sys.get_state(pid)
  end

  @tag :integration
  test "a TUI repainting an unchanged screen costs a frame, not one per repaint" do
    session = create_session!()
    pid = Server.whereis(session.id)
    ready!(pid)

    # 300 repaints of a row that never changes. Raw forwarding carries all
    # 300; a diffed frame carries the first and then has nothing to say.
    #
    # Counted while the alternate screen is still UP, for two reasons: the
    # server's retained window is byte-bounded and the exit resync (a full
    # normal viewport) evicts the frame we came to measure, and a loop that
    # finished inside one 10ms debounce window would correctly have rendered
    # nothing at all — the end state is the normal buffer, and a screen that
    # came and went within 10ms was never visible.
    shell(
      session,
      ~s|V=STE; printf '\\033[?1049h'; | <>
        ~s|for i in $(seq 1 #{@repaints}); do printf '\\033[1;1H%sADY' "$V"; done|
    )

    eventually("the alternate screen was painted", fn -> seen?(pid, "STEADY") end)
    _ = :sys.get_state(pid)
    painted = retained_output(pid) |> String.split("STEADY") |> length() |> Kernel.-(1)

    # Put the shell back before asserting, so a failure does not leave the
    # session wedged in the alternate screen for the teardown.
    shell(session, ~s|printf '\\033[?1049l'|)

    assert painted < 10,
           "expected #{@repaints} repaints to collapse into a frame or two, saw #{painted} " <>
             "copies — render mode is not collapsing the alternate screen"
  end

  @tag :integration
  test "the alternate screen still shows what the program drew" do
    session = create_session!()
    pid = Server.whereis(session.id)
    ready!(pid)

    run_and_await(
      session,
      pid,
      ~s|printf '\\033[?1049h\\033[H\\033[2J\\033[3;5H%sWN' "$V"; | <>
        ~s|sleep 0.15; printf '\\033[?1049l'|,
      "DRAWN"
    )

    output = retained_output(pid)

    # A frame's signature: the program addressed row 3 COLUMN 5, the frame
    # repaints whole rows from column 1.
    assert output =~ "\e[3;1H",
           "no absolute row addressing in the stream — the bytes were forwarded raw"
  end

  @tag :integration
  test "leaving the alternate screen hands the stream back without a RIS" do
    session = create_session!()
    pid = Server.whereis(session.id)
    ready!(pid)

    run_and_await(session, pid, "true", "BEFORE")

    run_and_await(
      session,
      pid,
      ~s|printf '\\033[?1049h\\033[H\\033[2J%sIDE' "$V"; | <>
        ~s|sleep 0.15; printf '\\033[?1049l'|,
      "INSIDE"
    )

    run_and_await(session, pid, "true", "AFTER")

    output = retained_output(pid)

    assert output =~ "\e[?1049l", "the client was never taken out of the alternate screen"

    # RIS would wipe the browser's scrollback: entering vim once would cost
    # the user their whole history.
    refute output =~ "\ec", "the alternate-screen handover must never emit RIS"
  end
end
