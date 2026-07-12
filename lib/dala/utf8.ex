defmodule Dala.Utf8 do
  @moduledoc """
  Recovering valid UTF-8 from byte-boundary cuts: truncations, tail reads and
  previews slice binaries at arbitrary offsets, and JSON encoding (Jason)
  requires valid strings.
  """

  @doc """
  Trims at most 3 trailing bytes off `binary` to recover a valid UTF-8 prefix
  (a cut can split one multi-byte character). Returns `{:ok, prefix}` or
  `:error` when the data is not UTF-8 text even after trimming.
  """
  def trim_partial_suffix(binary) when is_binary(binary) do
    Enum.find_value(0..3, :error, fn trim ->
      len = byte_size(binary) - trim

      with true <- len >= 0,
           prefix = binary_part(binary, 0, len),
           true <- String.valid?(prefix) do
        {:ok, prefix}
      else
        _ -> nil
      end
    end)
  end

  @doc """
  Caps `binary` at `max` bytes, cutting at a UTF-8 boundary so the truncated
  text still encodes as JSON. Input at or under the cap is returned unchanged;
  input that is not valid UTF-8 to begin with comes back as the raw byte cap.
  """
  def truncate(binary, max) when is_binary(binary) and byte_size(binary) <= max, do: binary

  def truncate(binary, max) when is_binary(binary) do
    slice = binary_part(binary, 0, max)

    case trim_partial_suffix(slice) do
      {:ok, prefix} -> prefix
      :error -> slice
    end
  end

  @doc """
  Drops every invalid byte sequence from `binary`, keeping the valid chunks —
  for data whose interior (not just the tail) may be damaged, e.g. mid-file
  tail reads.
  """
  def scrub(binary) when is_binary(binary) do
    if String.valid?(binary) do
      binary
    else
      binary |> String.chunk(:valid) |> Enum.filter(&String.valid?/1) |> Enum.join()
    end
  end
end
