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

  test "encodes explicit printable ASCII shortcuts as raw key bytes" do
    assert {:ok, [{"y", 15}, {"A", 15}, {"1", 15}, {"\r", 0}]} =
             Input.key_frames(["CHAR:y", "CHAR:A", "CHAR:1", "ENTER"])

    for invalid <- ["y", "CHAR:", "CHAR:yy", "CHAR: ", "CHAR:中", "CHAR:\e"] do
      assert {:error, message} = Input.key_frames([invalid])
      assert message =~ "unsupported terminal key"
    end
  end

  describe "Ctrl+letter keys" do
    test "every letter maps to its control byte" do
      assert {:ok, [{<<1>>, 0}]} = Input.key_frames(["CTRL_A"])
      assert {:ok, [{<<15>>, 0}]} = Input.key_frames(["CTRL_O"])
      assert {:ok, [{<<26>>, 0}]} = Input.key_frames(["CTRL_Z"])
    end

    test "the prefix chords real programs are driven by go through" do
      # zellij detach: Ctrl+O then d. This used to fail on the first key.
      assert {:ok, [{<<15>>, 15}, {"d", 0}]} = Input.key_frames(["CTRL_O", "CHAR:d"])
      # tmux prefix + c (new window), screen prefix + d (detach).
      assert {:ok, [{<<2>>, 15}, {"c", 0}]} = Input.key_frames(["CTRL_B", "CHAR:c"])
      assert {:ok, [{<<1>>, 15}, {"d", 0}]} = Input.key_frames(["CTRL_A", "CHAR:d"])
    end

    test "lowercase and non-letters are still refused" do
      assert {:error, message} = Input.key_frames(["CTRL_o"])
      assert message =~ "unsupported terminal key"
      assert {:error, _} = Input.key_frames(["CTRL_1"])
      assert {:error, _} = Input.key_frames(["CTRL_"])
    end

    test "the advertised key list covers the whole range" do
      keys = Input.supported_keys()

      assert "CTRL_A" in keys
      assert "CTRL_O" in keys
      assert "CTRL_Z" in keys
      assert length(Enum.filter(keys, &String.starts_with?(&1, "CTRL_"))) == 26
      # named_keys is what a schema enumerates; the range is matched by pattern.
      refute Enum.any?(Input.named_keys(), &String.starts_with?(&1, "CTRL_"))
    end
  end
end
