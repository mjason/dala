defmodule Dala.Terminal.AnsiText do
  @moduledoc false

  @type state :: :text | :escape | :csi | :osc | :osc_escape | :string | :string_escape

  @doc "Strip ANSI control sequences while preserving printable UTF-8 bytes across chunks."
  @spec filter(binary(), state()) :: {binary(), state()}
  def filter(data, state \\ :text) when is_binary(data) do
    {reversed, state} = do_filter(data, state, [])
    {reversed |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  defp do_filter(<<>>, state, out), do: {out, state}

  defp do_filter(<<0x1B, rest::binary>>, :text, out),
    do: do_filter(rest, :escape, out)

  defp do_filter(<<byte, rest::binary>>, :text, out) when byte in [9, 10, 13],
    do: do_filter(rest, :text, [<<byte>> | out])

  defp do_filter(<<byte, rest::binary>>, :text, out) when byte < 32 or byte == 127,
    do: do_filter(rest, :text, out)

  defp do_filter(<<byte, rest::binary>>, :text, out),
    do: do_filter(rest, :text, [<<byte>> | out])

  defp do_filter(<<"[", rest::binary>>, :escape, out), do: do_filter(rest, :csi, out)
  defp do_filter(<<"]", rest::binary>>, :escape, out), do: do_filter(rest, :osc, out)

  defp do_filter(<<byte, rest::binary>>, :escape, out) when byte in [?P, ?_, ?^],
    do: do_filter(rest, :string, out)

  defp do_filter(<<_byte, rest::binary>>, :escape, out), do: do_filter(rest, :text, out)

  defp do_filter(<<byte, rest::binary>>, :csi, out) when byte >= 0x40 and byte <= 0x7E,
    do: do_filter(rest, :text, out)

  defp do_filter(<<_byte, rest::binary>>, :csi, out), do: do_filter(rest, :csi, out)

  defp do_filter(<<7, rest::binary>>, :osc, out), do: do_filter(rest, :text, out)
  defp do_filter(<<0x1B, rest::binary>>, :osc, out), do: do_filter(rest, :osc_escape, out)
  defp do_filter(<<_byte, rest::binary>>, :osc, out), do: do_filter(rest, :osc, out)

  defp do_filter(<<"\\", rest::binary>>, :osc_escape, out), do: do_filter(rest, :text, out)
  defp do_filter(<<0x1B, rest::binary>>, :osc_escape, out), do: do_filter(rest, :osc_escape, out)
  defp do_filter(<<_byte, rest::binary>>, :osc_escape, out), do: do_filter(rest, :osc, out)

  defp do_filter(<<0x1B, rest::binary>>, :string, out),
    do: do_filter(rest, :string_escape, out)

  defp do_filter(<<_byte, rest::binary>>, :string, out), do: do_filter(rest, :string, out)

  defp do_filter(<<"\\", rest::binary>>, :string_escape, out), do: do_filter(rest, :text, out)

  defp do_filter(<<0x1B, rest::binary>>, :string_escape, out),
    do: do_filter(rest, :string_escape, out)

  defp do_filter(<<_byte, rest::binary>>, :string_escape, out),
    do: do_filter(rest, :string, out)
end
