defmodule Dala.Lsp.FramingTest do
  use ExUnit.Case, async: true

  alias Dala.Lsp.Framing

  test "encode → decode round-trips" do
    json = ~s({"jsonrpc":"2.0","id":1,"method":"initialize"})
    wire = IO.iodata_to_binary(Framing.encode(json))
    assert {[^json], ""} = Framing.decode(wire)
  end

  test "two messages in one chunk" do
    wire =
      IO.iodata_to_binary([Framing.encode(~s({"a":1})), Framing.encode(~s({"b":2}))])

    assert {[~s({"a":1}), ~s({"b":2})], ""} = Framing.decode(wire)
  end

  test "frames split across chunks accumulate" do
    wire = IO.iodata_to_binary(Framing.encode(~s({"key":"value"})))
    {first, second} = String.split_at(wire, 12)

    assert {[], rest} = Framing.decode(first)
    assert {[~s({"key":"value"})], ""} = Framing.decode(rest <> second)
  end

  test "extra headers (Content-Type) are tolerated" do
    body = ~s({"x":1})

    wire =
      "Content-Type: application/vscode-jsonrpc; charset=utf-8\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n\r\n" <> body

    assert {[^body], ""} = Framing.decode(wire)
  end

  test "multibyte payloads use byte length" do
    json = ~s({"msg":"中文测试"})
    wire = IO.iodata_to_binary(Framing.encode(json))
    assert {[^json], ""} = Framing.decode(wire)
  end

  test "garbage without a header stays buffered" do
    assert {[], "garbage"} = Framing.decode("garbage")
  end
end
