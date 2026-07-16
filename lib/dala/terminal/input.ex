defmodule Dala.Terminal.Input do
  @moduledoc false

  @image_exts ~w(.png .jpg .jpeg .gif .webp .bmp .svg .tif .tiff)

  @key_sequences %{
    "ENTER" => "\r",
    "ESC" => "\e",
    "TAB" => "\t",
    "UP" => "\e[A",
    "DOWN" => "\e[B",
    "LEFT" => "\e[D",
    "RIGHT" => "\e[C",
    "CTRL_C" => <<3>>,
    "CTRL_D" => <<4>>,
    "CTRL_Z" => <<26>>
  }

  @doc "Build serialized PTY frames as `{bytes, delay_after_ms}` tuples."
  def frames(app, text, attachments, submit, key \\ nil) do
    cond do
      is_binary(key) ->
        case Map.fetch(@key_sequences, key) do
          {:ok, sequence} -> {:ok, [{sequence, 0}]}
          :error -> {:error, "unsupported terminal key: #{key}"}
        end

      true ->
        build_message(app, text || "", attachments, submit)
    end
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
