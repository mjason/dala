defmodule Dala.Lsp.Framing do
  @moduledoc """
  LSP base-protocol framing: `Content-Length: N\\r\\n\\r\\n<N bytes>`.

  `decode/1` is a incremental parser over an accumulating buffer — stdio
  chunks split frames arbitrarily, so callers keep the returned rest as the
  next call's prefix.
  """

  @doc "Wraps one JSON-RPC message for the wire."
  def encode(json) when is_binary(json) do
    ["Content-Length: ", Integer.to_string(byte_size(json)), "\r\n\r\n", json]
  end

  @doc "Extracts complete messages: `{messages, rest}`."
  def decode(buffer), do: decode(buffer, [])

  defp decode(buffer, acc) do
    with [header, rest] <- :binary.split(buffer, "\r\n\r\n"),
         {:ok, length} <- content_length(header),
         <<body::binary-size(length), tail::binary>> <- rest do
      decode(tail, [body | acc])
    else
      # No full header yet, unparseable length, or truncated body.
      _ -> {Enum.reverse(acc), buffer}
    end
  end

  defp content_length(header) do
    header
    |> String.split("\r\n")
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          if String.downcase(String.trim(name)) == "content-length" do
            case Integer.parse(String.trim(value)) do
              {n, ""} when n >= 0 -> {:ok, n}
              _ -> nil
            end
          end

        _ ->
          nil
      end
    end)
  end
end
