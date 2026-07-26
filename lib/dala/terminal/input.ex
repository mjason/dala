defmodule Dala.Terminal.Input do
  @moduledoc false

  @image_exts ~w(.png .jpg .jpeg .gif .webp .bmp .svg .tif .tiff)

  @key_sequences %{
    "ENTER" => "\r",
    "ESC" => "\e",
    "TAB" => "\t",
    "BACKTAB" => "\e[Z",
    "SPACE" => " ",
    # DEL, not BS: that is what terminals send for the Backspace key, and what
    # readline and every TUI editor expects. Ctrl+H (BS) stays available as
    # CTRL_H for the programs that want it instead.
    "BACKSPACE" => <<127>>,
    "DELETE" => "\e[3~",
    "INSERT" => "\e[2~",
    "HOME" => "\e[H",
    "END" => "\e[F",
    "PAGE_UP" => "\e[5~",
    "PAGE_DOWN" => "\e[6~",
    # Alt as one write, never ESC-then-key in two frames: TUIs tell the two
    # apart by timing, and a gap would read as "pressed Escape, then Enter".
    "ALT_ENTER" => "\e\r",
    "SHIFT_TAB" => "\e[Z",
    # The C0 controls that are not Ctrl+letter. Named rather than matched by
    # pattern: there are only these few, and "\\" and "^" inside a JSON Schema
    # regex are awkward to write and worse to guess. Ctrl+[ and Ctrl+? are
    # deliberately absent — they are ESC and BACKSPACE, already above.
    "CTRL_SPACE" => <<0>>,
    "CTRL_BACKSLASH" => <<28>>,
    "CTRL_RIGHT_BRACKET" => <<29>>,
    "CTRL_CARET" => <<30>>,
    "CTRL_UNDERSCORE" => <<31>>
  }
  # xterm modifier encoding: 2 = Shift, 3 = Alt, 5 = Ctrl. These are how panes
  # and words are navigated (zellij Alt+arrows, readline Ctrl+arrows).
  @arrow_finals %{"UP" => "A", "DOWN" => "B", "RIGHT" => "C", "LEFT" => "D"}
  @arrow_modifiers %{"SHIFT" => 2, "ALT" => 3, "CTRL" => 5}
  @modified_arrows for {modifier, code} <- @arrow_modifiers,
                       {arrow, final} <- @arrow_finals,
                       into: %{},
                       do: {"#{modifier}_#{arrow}", "\e[1;#{code}#{final}"}
  # F1-F4 are SS3 (what xterm sends); F5 up are CSI with the usual gaps.
  @function_keys %{
    "F1" => "\eOP",
    "F2" => "\eOQ",
    "F3" => "\eOR",
    "F4" => "\eOS",
    "F5" => "\e[15~",
    "F6" => "\e[17~",
    "F7" => "\e[18~",
    "F8" => "\e[19~",
    "F9" => "\e[20~",
    "F10" => "\e[21~",
    "F11" => "\e[23~",
    "F12" => "\e[24~"
  }
  @cursor_keys ~w(UP DOWN LEFT RIGHT)
  @named_keys (Map.keys(@key_sequences) ++
                 Map.keys(@modified_arrows) ++ Map.keys(@function_keys) ++ @cursor_keys)
              |> Enum.sort()
  # Every Ctrl+letter, not a hand-picked few: the prefix keys real programs are
  # driven by are all in here (zellij Ctrl+O/Ctrl+G, tmux Ctrl+B, screen
  # Ctrl+A, readline Ctrl+U/K/W/R, claude's Ctrl+O reflow). A short allowlist
  # bought no safety either — the same tool already types arbitrary text and
  # presses Enter, which is strictly more powerful than any control byte.
  @ctrl_keys for letter <- ?A..?Z, do: "CTRL_" <> <<letter>>
  @supported_keys @named_keys ++ @ctrl_keys

  def supported_keys, do: @supported_keys

  @doc "The named keys, without the CTRL_A..CTRL_Z range (schemas match those by pattern)."
  def named_keys, do: @named_keys

  @doc "Build serialized PTY frames as `{bytes, delay_after_ms}` tuples."
  def frames(app, text, attachments, submit, key \\ nil, opts \\ []) do
    cond do
      is_binary(key) ->
        key_frames([key], opts)

      true ->
        build_message(app, text || "", attachments, submit)
    end
  end

  @doc "Build a bounded, paced sequence of safe terminal key frames."
  def key_frames(keys, opts \\ [])

  def key_frames(keys, opts) when is_list(keys) and keys != [] and length(keys) <= 100 do
    application_cursor? = Keyword.get(opts, :application_cursor, false)

    with {:ok, sequences} <- key_sequences(keys, application_cursor?) do
      last = length(sequences) - 1

      {:ok,
       sequences
       |> Enum.with_index()
       |> Enum.map(fn {sequence, index} -> {sequence, if(index == last, do: 0, else: 15)} end)}
    end
  end

  def key_frames(_keys, _opts),
    do: {:error, "keys must contain between 1 and 100 supported terminal keys"}

  defp key_sequences(keys, application_cursor?) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, sequences} ->
      case key_sequence(key, application_cursor?) do
        {:ok, sequence} -> {:cont, {:ok, [sequence | sequences]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, sequences} -> {:ok, Enum.reverse(sequences)}
      error -> error
    end
  end

  defp key_sequence(key, application_cursor?) when key in @cursor_keys do
    final = %{"UP" => "A", "DOWN" => "B", "RIGHT" => "C", "LEFT" => "D"}[key]
    {:ok, if(application_cursor?, do: "\eO#{final}", else: "\e[#{final}")}
  end

  defp key_sequence("HOME", true), do: {:ok, "\eOH"}
  defp key_sequence("END", true), do: {:ok, "\eOF"}

  # One key, any script: a TUI hotkey may be 好, é or 👍. Exactly one grapheme
  # (an emoji with modifiers counts as one) and no control characters — those
  # have names of their own, and letting them in here would be a second, silent
  # way to send them.
  defp key_sequence(<<"CHAR:", rest::binary>>, _application_cursor?) when rest != "" do
    with true <- byte_size(rest) <= 16,
         [_single] <- String.graphemes(rest),
         true <- printable_key?(rest) do
      {:ok, rest}
    else
      _not_one_printable_character ->
        {:error, "CHAR: takes exactly one non-control character, got #{inspect(rest)}"}
    end
  end

  # Ctrl+letter is the letter with its top three bits cleared: Ctrl+A is 1,
  # Ctrl+C is 3 (SIGINT), Ctrl+Z is 26.
  defp key_sequence(<<"CTRL_", letter>>, _application_cursor?) when letter in ?A..?Z,
    do: {:ok, <<letter - ?A + 1>>}

  defp key_sequence(<<"ALT:", byte>>, _application_cursor?) when byte in ?!..?~,
    do: {:ok, <<0x1B, byte>>}

  defp key_sequence(key, _application_cursor?) do
    case Map.fetch(Map.merge(@key_sequences, Map.merge(@modified_arrows, @function_keys)), key) do
      {:ok, sequence} -> {:ok, sequence}
      :error -> {:error, "unsupported terminal key: #{inspect(key)}"}
    end
  end

  defp printable_key?(text) do
    String.valid?(text) and
      not String.match?(text, ~r/[\x00-\x1f\x7f]/)
  end

  defp build_message(app, text, attachments, submit) do
    with {:ok, paths} <- validate_attachments(attachments) do
      attachment_frames =
        Enum.map(paths, fn path ->
          prefix = if not image?(path) and app in ~w(claude gemini), do: "@", else: ""
          {bracket(prefix <> path <> " "), 200}
        end)

      rest = String.trim(text)

      frames =
        cond do
          paths != [] ->
            rest_frames =
              if rest == "", do: [], else: [{frame_body(rest, mode(app, rest)), 120}]

            submit_frames = if submit, do: [{"\r", 0}], else: []
            attachment_frames ++ rest_frames ++ submit_frames

          rest != "" ->
            message_frames(app, rest, submit)

          submit ->
            [{"\r", 0}]

          true ->
            []
        end

      if frames == [],
        do: {:error, "text, attachments, submit or key is required"},
        else: {:ok, frames}
    end
  end

  defp message_frames(app, text, submit) do
    mode = mode(app, text)
    {prefix_frames, text} = split_mode_prefix(text, mode)
    body = frame_body(text, mode)

    frames =
      cond do
        not submit -> [{body, 0}]
        mode == :delayed -> [{body, 50}, {"\r", 0}]
        mode == :bracketed_delayed -> [{body, 300}, {"\r", 0}]
        true -> [{body, 0}, {"\r", 0}]
      end

    prefix_frames ++ frames
  end

  defp mode("codex", _text), do: :bracketed
  defp mode("copilot", _text), do: :bracketed_delayed
  defp mode(app, text) when app in ~w(claude opencode gemini), do: multiline_mode(text)
  defp mode(_app, _text), do: :inline

  defp multiline_mode(text),
    do: if(String.contains?(text, "\n"), do: :bracketed_delayed, else: :delayed)

  defp frame_body(text, mode) when mode in [:bracketed, :bracketed_delayed], do: bracket(text)
  defp frame_body(text, _mode), do: text
  defp bracket(text), do: "\e[200~" <> text <> "\e[201~"

  defp split_mode_prefix(<<prefix, rest::binary>>, mode)
       when prefix in [?!, ?&] and mode in [:inline, :delayed],
       do: {[{<<prefix>>, 50}], rest}

  defp split_mode_prefix(text, _mode), do: {[], text}

  defp validate_attachments(paths) when is_list(paths) and length(paths) <= 20 do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, valid} ->
      if is_binary(path) do
        case Dala.Terminal.Attachments.validate_path(path) do
          {:ok, expanded} -> {:cont, {:ok, [expanded | valid]}}
          {:error, message} -> {:halt, {:error, message}}
        end
      else
        {:halt, {:error, "every attachment must be a server file path"}}
      end
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.reverse(valid)}
      error -> error
    end
  end

  defp validate_attachments(_paths), do: {:error, "attachments must contain at most 20 paths"}

  defp image?(path), do: String.downcase(Path.extname(path)) in @image_exts
end
