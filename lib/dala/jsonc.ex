defmodule Dala.Jsonc do
  @moduledoc """
  Just enough JSONC for config files, without pulling in a parser dependency:
  `strip/1` removes `//` and `/* */` comments outside strings plus trailing
  commas, leaving plain JSON for `Jason.decode/1`.
  """

  @doc "Strips comments and trailing commas; the result is decodable JSON text."
  def strip(body) do
    body
    |> scan([], :code)
    |> IO.iodata_to_binary()
    |> String.replace(~r/,(\s*[}\]])/, "\\1")
  end

  defp scan(<<>>, acc, _state), do: Enum.reverse(acc)

  defp scan(<<?\\, ?", rest::binary>>, acc, :string),
    do: scan(rest, ["\\\"" | acc], :string)

  defp scan(<<?", rest::binary>>, acc, :string), do: scan(rest, [?" | acc], :code)

  defp scan(<<c::utf8, rest::binary>>, acc, :string),
    do: scan(rest, [<<c::utf8>> | acc], :string)

  defp scan(<<?", rest::binary>>, acc, :code), do: scan(rest, [?" | acc], :string)
  defp scan(<<"//", rest::binary>>, acc, :code), do: scan(rest, acc, :line_comment)
  defp scan(<<"/*", rest::binary>>, acc, :code), do: scan(rest, acc, :block_comment)

  defp scan(<<c::utf8, rest::binary>>, acc, :code),
    do: scan(rest, [<<c::utf8>> | acc], :code)

  defp scan(<<?\n, rest::binary>>, acc, :line_comment),
    do: scan(rest, [?\n | acc], :code)

  defp scan(<<_c::utf8, rest::binary>>, acc, :line_comment),
    do: scan(rest, acc, :line_comment)

  defp scan(<<"*/", rest::binary>>, acc, :block_comment), do: scan(rest, acc, :code)

  defp scan(<<_c::utf8, rest::binary>>, acc, :block_comment),
    do: scan(rest, acc, :block_comment)
end
