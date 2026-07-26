defmodule Dala.Terminal.AnsiText do
  @moduledoc false

  @on_load :__prime_pattern__

  @type state :: :text | :escape | :csi | :osc | :osc_escape | :string | :string_escape

  # Every byte that cannot appear in plain text: ESC, which opens a sequence,
  # and the other C0 controls plus DEL, which are simply dropped. Tab, newline
  # and carriage return are text and deliberately absent.
  @strippable for b <- Enum.to_list(0..31) ++ [127], b not in [9, 10, 13], do: <<b>>

  @doc """
  Strip ANSI control sequences while preserving printable UTF-8 bytes across
  chunks.

  This runs on the session's own GenServer for output a shell can produce far
  faster than it can be broadcast, so the shape matters: ONE compiled-pattern
  scan decides whether the chunk needs work at all, and the byte-wise state
  machine behind it accumulates printable bytes as integers (iodata takes them
  directly) instead of allocating a heap binary per byte.

  Scanning per printable run instead — the obvious next step — is a trap: a
  clause that binds the remaining data as a plain variable destroys the
  compiler's binary match-context reuse, and paying that back on every escape
  sequence made TUI output ~9x SLOWER than the byte-wise machine it replaced.
  """
  @spec filter(binary(), state()) :: {binary(), state()}
  def filter(data, state \\ :text)

  def filter(data, :text) when is_binary(data) do
    case :binary.match(data, strippable_pattern()) do
      # Plain output — a build log, `cat`, program stdout — is returned as is.
      :nomatch ->
        {data, :text}

      {0, _length} ->
        run(data, :text)

      # A printable head followed by sequences: the head is kept whole and only
      # the remainder walks the machine.
      {position, _length} ->
        <<head::binary-size(position), rest::binary>> = data
        {tail, state} = run(rest, :text)
        {head <> tail, state}
    end
  end

  def filter(data, state) when is_binary(data), do: run(data, state)

  defp run(data, state) do
    {reversed, state} = do_filter(data, state, [])
    {reversed |> Enum.reverse() |> IO.iodata_to_binary(), state}
  end

  defp do_filter(<<>>, state, out), do: {out, state}

  defp do_filter(<<0x1B, rest::binary>>, :text, out),
    do: do_filter(rest, :escape, out)

  defp do_filter(<<byte, rest::binary>>, :text, out) when byte in [9, 10, 13],
    do: do_filter(rest, :text, [byte | out])

  defp do_filter(<<byte, rest::binary>>, :text, out) when byte < 32 or byte == 127,
    do: do_filter(rest, :text, out)

  defp do_filter(<<byte, rest::binary>>, :text, out),
    do: do_filter(rest, :text, [byte | out])

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

  # Compiling the alternation on every chunk would give back what the scan
  # saves, and a compiled pattern is a reference, so it cannot live in a module
  # attribute. Priming it at load time keeps the hot path a bare lookup and puts
  # the one-off global literal scan at startup rather than mid-session.
  @doc false
  def __prime_pattern__ do
    :persistent_term.put({__MODULE__, :strippable}, :binary.compile_pattern(@strippable))
    :ok
  end

  defp strippable_pattern, do: :persistent_term.get({__MODULE__, :strippable})
end
