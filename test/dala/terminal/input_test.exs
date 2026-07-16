defmodule Dala.Terminal.InputTest do
  use ExUnit.Case, async: true

  alias Dala.Terminal.Input

  test "uses each foreground agent's paste and Enter timing" do
    assert {:ok, [{"\e[200~hello\e[201~", 0}, {"\r", 0}]} =
             Input.frames("codex", "hello", [], true)

    assert {:ok, [{"hello", 50}, {"\r", 0}]} =
             Input.frames("claude", "hello", [], true)

    assert {:ok, [{"\e[200~one\ntwo\e[201~", 300}, {"\r", 0}]} =
             Input.frames("gemini", "one\ntwo", [], true)
  end

  test "sends Claude mode prefixes separately" do
    assert {:ok, [{"!", 50}, {"ls", 50}, {"\r", 0}]} =
             Input.frames("claude", "!ls", [], true)
  end

  test "text files become @ references for Claude while images stay bare" do
    root = Path.join(System.tmp_dir!(), "dala-input-#{System.unique_integer([:positive])}")
    text = Path.join(root, "notes.txt")
    image = Path.join(root, "screen.png")
    File.mkdir_p!(root)
    File.write!(text, "notes")
    File.write!(image, "image")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, [{text_frame, 200}, {image_frame, 200}]} =
             Input.frames("claude", "", [text, image], false)

    assert text_frame == "\e[200~@#{text} \e[201~"
    assert image_frame == "\e[200~#{image} \e[201~"
  end

  test "supports bounded control keys and rejects non-path attachments" do
    assert {:ok, [{<<3>>, 0}]} = Input.frames("shell", "", [], false, "CTRL_C")
    assert {:ok, [{"\e[H", 0}]} = Input.frames("shell", "", [], false, "HOME")
    assert {:error, _message} = Input.frames("shell", "", [123], false)
  end

  test "paces TUI key sequences and respects application cursor mode" do
    assert {:ok, [{"\eOB", 15}, {"\eOB", 15}, {" ", 15}, {"\e[6~", 15}, {"\r", 0}]} =
             Input.key_frames(~w(DOWN DOWN SPACE PAGE_DOWN ENTER), application_cursor: true)

    assert {:ok, [{"\e[A", 15}, {"\e[B", 0}]} = Input.key_frames(~w(UP DOWN))
    assert {:error, message} = Input.key_frames(["RAW_BYTES"])
    assert message =~ "unsupported terminal key"
  end
end
