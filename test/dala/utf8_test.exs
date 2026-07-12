defmodule Dala.Utf8Test do
  use ExUnit.Case, async: true

  alias Dala.Utf8

  # "é" = <<0xC3, 0xA9>>, "中" = <<0xE4, 0xB8, 0xAD>>, "😀" = 4 bytes
  describe "trim_partial_suffix/1" do
    test "valid text is returned unchanged" do
      assert Utf8.trim_partial_suffix("hello 中文") == {:ok, "hello 中文"}
    end

    test "recovers from a split 2-byte character" do
      <<partial::binary-size(1), _::binary>> = "é"
      assert Utf8.trim_partial_suffix("abc" <> partial) == {:ok, "abc"}
    end

    test "recovers from a split 4-byte character" do
      <<partial::binary-size(3), _::binary>> = "😀"
      assert Utf8.trim_partial_suffix("abc" <> partial) == {:ok, "abc"}
    end

    test "errors when the data is not text at all" do
      assert Utf8.trim_partial_suffix(<<0xFF, 0xFE, 0xFF, 0xFE, 0xFF>>) == :error
    end

    test "empty binary is valid" do
      assert Utf8.trim_partial_suffix("") == {:ok, ""}
    end

    test "binaries shorter than the trim window do not underflow" do
      assert Utf8.trim_partial_suffix(<<0xE4>>) == {:ok, ""}
    end
  end

  describe "truncate/2" do
    test "input at or under the cap is returned unchanged" do
      assert Utf8.truncate("abc", 3) == "abc"
      assert Utf8.truncate("abc", 10) == "abc"
    end

    test "cuts at the byte cap on an ASCII boundary" do
      assert Utf8.truncate("abcdef", 4) == "abcd"
    end

    test "backs off a cut that splits a multi-byte character" do
      # "ab中" is 5 bytes; capping at 4 lands mid-中
      assert Utf8.truncate("ab中", 4) == "ab"
    end

    test "keeps a multi-byte character that fits exactly" do
      assert Utf8.truncate("ab中xyz", 5) == "ab中"
    end

    test "non-text input comes back as the raw byte cap" do
      data = :binary.copy(<<0xFF>>, 10)
      assert Utf8.truncate(data, 4) == :binary.copy(<<0xFF>>, 4)
    end
  end

  describe "scrub/1" do
    test "valid text is returned unchanged" do
      assert Utf8.scrub("hello 中文 😀") == "hello 中文 😀"
    end

    test "drops invalid bytes in the middle, keeping surrounding text" do
      assert Utf8.scrub("ab" <> <<0xFF, 0xFE>> <> "cd") == "abcd"
    end

    test "drops a split character at the tail" do
      <<partial::binary-size(1), _::binary>> = "é"
      assert Utf8.scrub("abc" <> partial) == "abc"
    end

    test "all-invalid input scrubs to the empty string" do
      assert Utf8.scrub(<<0xFF, 0xFE>>) == ""
    end
  end
end
