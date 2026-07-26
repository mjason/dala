defmodule Dala.Terminal.AnsiTextTest do
  use ExUnit.Case, async: true

  alias Dala.Terminal.AnsiText

  test "strips CSI styling and OSC metadata while preserving unicode text" do
    input = "before \e[31m红色\e[0m \e]7;file://host/tmp\aafter"
    assert {"before 红色 after", :text} = AnsiText.filter(input)
  end

  test "keeps parser state when an escape sequence crosses chunks" do
    {first, state} = AnsiText.filter("needle\e[38;2")
    {second, state} = AnsiText.filter(";1;2;3m-tail\e]title", state)
    {third, state} = AnsiText.filter(" ignored\e", state)
    {fourth, state} = AnsiText.filter("\\done", state)

    assert first <> second <> third <> fourth == "needle-taildone"
    assert state == :text
  end

  test "keeps tab, newline and carriage return but drops other control bytes" do
    assert {"a\tb\nc\rd", :text} = AnsiText.filter("a\tb\nc\rd")
    assert {"ab", :text} = AnsiText.filter("a\b\v\f\0\x7fb")
  end

  test "long printable runs survive untouched" do
    text = String.duplicate("plain build output line\n", 4_000)
    assert {^text, :text} = AnsiText.filter(text)
  end

  test "multi-byte UTF-8 is never split by the printable fast path" do
    text = String.duplicate("中文と日本語 ✅ ", 500)
    assert {^text, :text} = AnsiText.filter(text)
    assert {^text, :text} = AnsiText.filter("\e[1m" <> text <> "\e[0m")
  end

  test "strips control bytes that follow a printable run in the same chunk" do
    assert {"head\ttail", :text} = AnsiText.filter("head\t\x01\x02tail")
  end

  test "a long printable head is kept whole ahead of a sequence-laden tail" do
    head = String.duplicate("plain build line with no escape at all\n", 500)

    assert {plain, :text} = AnsiText.filter(head <> "\e[1mbold\e[0m\x07 end")
    assert plain == head <> "bold end"
  end

  test "an already-open sequence is resumed without rescanning as text" do
    assert {"", :csi} = AnsiText.filter("38;5;", :csi)
    assert {"tail", :text} = AnsiText.filter("39mtail", :csi)
    assert {"", :osc} = AnsiText.filter("0;a title", :osc)
    assert {"prompt", :text} = AnsiText.filter("\aprompt", :osc)
  end

  test "handles DCS, APC and PM strings terminated by ST" do
    assert {"ab", :text} = AnsiText.filter("a\eP1;2q ignored \e\\b")
    assert {"ab", :text} = AnsiText.filter("a\e_dala payload\e\\b")
    assert {"ab", :text} = AnsiText.filter("a\e^private\e\\b")
  end

  test "an ESC at the very end of a chunk is carried into the next" do
    {first, state} = AnsiText.filter("keep\e")
    assert first == "keep"
    assert state == :escape
    assert {"more", :text} = AnsiText.filter("[0mmore", state)
  end

  # The filter runs on the session's own GenServer for every byte a shell
  # prints, so it shares the critical path with keystrokes, resize and
  # repaint. A byte-at-a-time implementation cost ~13x a base64 encode of the
  # same data; anchoring the gate to that cheap primitive keeps it meaningful
  # on machines of any speed.
  test "filtering printable output stays cheap relative to base64 encoding it" do
    chunk = String.duplicate("hello world some plain build output line\r\n", 1_200)

    assert_cost_ratio(chunk, 3.0, "the printable fast path")
  end

  # Escape-dense output is the other half of the picture, and the easy one to
  # regress: scanning for printable runs one at a time reads as an optimization
  # but breaks the compiler's binary match-context reuse, which cost ~9x here.
  test "filtering escape-dense output stays cheap too" do
    tui = String.duplicate("\e[38;5;39m\e[1m▍\e[0m \e[2mstatus\e[0m \e[K\e[1;24r\e[H", 1_000)
    osc = String.duplicate("\e]0;a window title\aprompt$ ", 1_500)

    assert_cost_ratio(tui, 8.0, "the escape state machine")
    assert_cost_ratio(osc, 8.0, "the OSC state machine")
  end

  # Anchored to a cheap primitive over the same bytes so the gate means the same
  # thing on machines of any speed.
  defp assert_cost_ratio(chunk, limit, what) do
    runs = 80

    {filter_us, _} =
      :timer.tc(fn -> Enum.each(1..runs, fn _ -> AnsiText.filter(chunk, :text) end) end)

    {base64_us, _} =
      :timer.tc(fn -> Enum.each(1..runs, fn _ -> Base.encode64(chunk) end) end)

    ratio = filter_us / max(base64_us, 1)

    assert ratio < limit,
           "AnsiText.filter cost #{Float.round(ratio, 2)}x a base64 encode of the same bytes " <>
             "(filter #{filter_us}us vs base64 #{base64_us}us); #{what} regressed"
  end
end
