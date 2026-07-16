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
end
