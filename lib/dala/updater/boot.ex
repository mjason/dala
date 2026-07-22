defmodule Dala.Updater.Boot do
  @moduledoc false

  # `start.boot` is an Erlang external term supplied by the release archive.
  # Parse its small identity envelope without decoding atoms into the VM.
  @etf_version 131
  @nil_tag 106
  @max_bytes 8 * 1024 * 1024
  @max_depth 128
  @max_nodes 200_000
  @max_collection_items 200_000
  @max_atom_bytes 1_024
  @max_text_bytes 4_096

  @spec validate(binary(), String.t()) :: :ok | {:error, atom()}
  def validate(contents, expected_version)
      when is_binary(contents) and is_binary(expected_version) do
    cond do
      byte_size(contents) > @max_bytes -> {:error, :too_large}
      byte_size(expected_version) > @max_text_bytes -> {:error, :invalid_version}
      true -> parse(contents, expected_version)
    end
  end

  def validate(_contents, _expected_version), do: {:error, :invalid_term}

  defp parse(binary, expected_version) do
    with <<@etf_version, rest::binary>> <- binary,
         {:ok, 3, position, nodes} <- tuple_header(rest, 0, 0, 0),
         {:ok, "script", position, nodes} <- atom_term(rest, position, 1, nodes),
         {:ok, 2, position, nodes} <- tuple_header(rest, position, 1, nodes),
         {:ok, "dala", position, nodes} <- text_term(rest, position, 2, nodes),
         {:ok, ^expected_version, position, nodes} <-
           text_term(rest, position, 2, nodes),
         {:ok, count, position, nodes} <- list_header(rest, position, 1, nodes),
         true <- count > 0 and count <= @max_collection_items,
         {:ok, position, nodes} <- skip_terms(rest, position, count, 2, nodes),
         {:ok, position, _nodes_after_tail, @nil_tag} <- skip_term(rest, position, 2, nodes),
         true <- position == byte_size(rest) do
      :ok
    else
      _ -> {:error, :invalid_term}
    end
  end

  defp tuple_header(binary, position, depth, nodes) do
    with {:ok, tag, position, nodes} <- begin_term(binary, position, depth, nodes),
         {:ok, arity, position} <-
           (case tag do
              104 -> read_uint(binary, position, 1)
              105 -> read_uint(binary, position, 4)
              _ -> {:error, :invalid_tuple}
            end),
         true <- arity <= @max_collection_items do
      {:ok, arity, position, nodes}
    else
      _ -> {:error, :invalid_tuple}
    end
  end

  defp list_header(binary, position, depth, nodes) do
    with {:ok, 108, position, nodes} <- begin_term(binary, position, depth, nodes),
         {:ok, count, position} <- read_uint(binary, position, 4),
         true <- count <= @max_collection_items do
      {:ok, count, position, nodes}
    else
      _ -> {:error, :invalid_list}
    end
  end

  defp atom_term(binary, position, depth, nodes) do
    with {:ok, tag, position, nodes} <- begin_term(binary, position, depth, nodes),
         true <- tag in [100, 115, 118, 119],
         {:ok, length, position} <- atom_length(binary, position, tag),
         {:ok, bytes, position} <- read_bytes(binary, position, length, @max_atom_bytes),
         {:ok, value} <- decode_atom(tag, bytes) do
      {:ok, value, position, nodes}
    else
      _ -> {:error, :invalid_atom}
    end
  end

  defp text_term(binary, position, depth, nodes) do
    with {:ok, tag, position, nodes} <- begin_term(binary, position, depth, nodes) do
      case tag do
        tag when tag in [100, 115, 118, 119] ->
          with {:ok, length, position} <- atom_length(binary, position, tag),
               {:ok, bytes, position} <- read_bytes(binary, position, length, @max_text_bytes),
               {:ok, value} <- decode_atom(tag, bytes) do
            {:ok, value, position, nodes}
          else
            _ -> {:error, :invalid_text}
          end

        107 ->
          with {:ok, length, position} <- read_uint(binary, position, 2),
               {:ok, bytes, position} <- read_bytes(binary, position, length, @max_text_bytes),
               {:ok, value} <- decode_latin1(bytes) do
            {:ok, value, position, nodes}
          else
            _ -> {:error, :invalid_text}
          end

        109 ->
          with {:ok, length, position} <- read_uint(binary, position, 4),
               {:ok, bytes, position} <- read_bytes(binary, position, length, @max_text_bytes),
               {:ok, value} <- decode_utf8(bytes) do
            {:ok, value, position, nodes}
          else
            _ -> {:error, :invalid_text}
          end

        108 ->
          with {:ok, count, position} <- read_uint(binary, position, 4),
               true <- count <= @max_text_bytes,
               {:ok, codepoints, position, nodes} <-
                 read_charlist(binary, position, count, depth + 1, nodes, []),
               {:ok, position, nodes, @nil_tag} <- skip_term(binary, position, depth + 1, nodes),
               {:ok, value} <- codepoints_to_string(codepoints) do
            {:ok, value, position, nodes}
          else
            _ -> {:error, :invalid_text}
          end

        _ ->
          {:error, :invalid_text}
      end
    else
      _ -> {:error, :invalid_text}
    end
  end

  defp read_charlist(binary, position, count, depth, nodes, acc) when count >= 0 do
    read_charlist_loop(binary, position, count, depth, nodes, acc)
  end

  defp read_charlist_loop(_binary, position, 0, _depth, nodes, acc),
    do: {:ok, Enum.reverse(acc), position, nodes}

  defp read_charlist_loop(binary, position, count, depth, nodes, acc) when count > 0 do
    with {:ok, tag, position, nodes} <- begin_term(binary, position, depth, nodes),
         {:ok, value, position} <-
           (case tag do
              97 -> read_uint(binary, position, 1)
              98 -> read_signed_int(binary, position)
              _ -> {:error, :invalid_charlist}
            end),
         true <- value >= 0 and value <= 0x10FFFF do
      read_charlist_loop(binary, position, count - 1, depth, nodes, [value | acc])
    else
      _ -> {:error, :invalid_charlist}
    end
  end

  defp codepoints_to_string(codepoints) do
    case :unicode.characters_to_binary(codepoints) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :invalid_charlist}
    end
  end

  defp skip_terms(binary, position, count, depth, nodes) when count >= 0 do
    skip_terms_loop(binary, position, count, depth, nodes)
  end

  # Keep sibling traversal tail-recursive: a forged 200k-element collection
  # must hit the node limit, not consume one BEAM stack frame per element.
  defp skip_terms_loop(_binary, position, 0, _depth, nodes), do: {:ok, position, nodes}

  defp skip_terms_loop(binary, position, count, depth, nodes) when count > 0 do
    case skip_term(binary, position, depth, nodes) do
      {:ok, position, nodes, _tag} ->
        skip_terms_loop(binary, position, count - 1, depth, nodes)

      _ ->
        {:error, :invalid_term}
    end
  end

  defp skip_term(binary, position, depth, nodes) do
    with {:ok, tag, position, nodes} <- begin_term(binary, position, depth, nodes),
         {:ok, position, nodes} <- skip_payload(binary, position, tag, depth, nodes) do
      {:ok, position, nodes, tag}
    else
      _ -> {:error, :invalid_term}
    end
  end

  defp skip_payload(binary, position, tag, _depth, nodes)
       when tag in [70, 97, 98, 99, 100, 106, 107, 109, 110, 111, 115, 118, 119] do
    case tag do
      70 -> advance_with_nodes(binary, position, 8, nodes)
      97 -> advance_with_nodes(binary, position, 1, nodes)
      98 -> advance_with_nodes(binary, position, 4, nodes)
      99 -> old_float_payload(binary, position, nodes)
      100 -> validated_atom_payload(binary, position, 100, nodes)
      106 -> {:ok, position, nodes}
      107 -> sized_payload(binary, position, 2, @max_text_bytes, nodes)
      109 -> sized_payload(binary, position, 4, @max_bytes, nodes)
      110 -> big_payload(binary, position, 1, nodes)
      111 -> big_payload(binary, position, 4, nodes)
      115 -> validated_atom_payload(binary, position, 115, nodes)
      118 -> validated_atom_payload(binary, position, 118, nodes)
      119 -> validated_atom_payload(binary, position, 119, nodes)
    end
  end

  defp skip_payload(binary, position, 77, _depth, nodes) do
    with {:ok, length, position} <- read_uint(binary, position, 4),
         {:ok, bits, position} <- read_uint(binary, position, 1),
         true <- bits in 1..8,
         true <- length > 0,
         true <- length <= @max_bytes,
         {:ok, position} <- advance(binary, position, length) do
      {:ok, position, nodes}
    else
      _ -> {:error, :invalid_bitstring}
    end
  end

  defp skip_payload(binary, position, tag, depth, nodes) when tag in [104, 105] do
    with {:ok, arity, position} <-
           (case tag do
              104 -> read_uint(binary, position, 1)
              105 -> read_uint(binary, position, 4)
            end),
         true <- arity <= @max_collection_items,
         {:ok, position, nodes} <- skip_terms(binary, position, arity, depth + 1, nodes) do
      {:ok, position, nodes}
    else
      _ -> {:error, :invalid_tuple}
    end
  end

  defp skip_payload(binary, position, 108, depth, nodes) do
    with {:ok, count, position} <- read_uint(binary, position, 4),
         true <- count <= @max_collection_items,
         {:ok, position, nodes} <- skip_terms(binary, position, count, depth + 1, nodes),
         {:ok, position, nodes, _tail} <- skip_term(binary, position, depth + 1, nodes) do
      {:ok, position, nodes}
    else
      _ -> {:error, :invalid_list}
    end
  end

  defp skip_payload(binary, position, 116, depth, nodes) do
    with {:ok, count, position} <- read_uint(binary, position, 4),
         true <- count <= @max_collection_items,
         {:ok, position, nodes} <- skip_terms(binary, position, count * 2, depth + 1, nodes) do
      {:ok, position, nodes}
    else
      _ -> {:error, :invalid_map}
    end
  end

  defp skip_payload(_binary, _position, _tag, _depth, _nodes),
    do: {:error, :unsupported_term}

  defp old_float_payload(binary, position, nodes) do
    with {:ok, bytes, position} <- read_bytes(binary, position, 31, 31),
         <<body::binary-size(30), 0>> <- bytes,
         {:ok, _literal} <- old_float_literal(body) do
      {:ok, position, nodes}
    else
      _ -> {:error, :invalid_float}
    end
  end

  defp old_float_literal(body) do
    literal = body |> :binary.split(<<0>>, [:global]) |> hd()

    if byte_size(literal) > 0 and
         Enum.all?(:binary.bin_to_list(literal), &(&1 in 0x20..0x7E)) do
      {:ok, literal}
    else
      {:error, :invalid_float}
    end
  end

  defp validated_atom_payload(binary, position, tag, nodes) do
    with {:ok, length, position} <- atom_length(binary, position, tag),
         {:ok, bytes, position} <- read_bytes(binary, position, length, @max_atom_bytes),
         {:ok, _value} <- decode_atom(tag, bytes) do
      {:ok, position, nodes}
    else
      _ -> {:error, :invalid_atom}
    end
  end

  defp big_payload(binary, position, count_bytes, nodes) do
    with {:ok, count, position} <- read_uint(binary, position, count_bytes),
         true <- count <= @max_collection_items,
         {:ok, sign, position} <- read_uint(binary, position, 1),
         true <- sign in [0, 1],
         {:ok, position} <- advance(binary, position, count) do
      {:ok, position, nodes}
    else
      _ -> {:error, :invalid_integer}
    end
  end

  defp sized_payload(binary, position, width, max_length, nodes) do
    with {:ok, length, position} <- read_uint(binary, position, width),
         true <- length <= max_length,
         {:ok, position} <- advance(binary, position, length) do
      {:ok, position, nodes}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp begin_term(binary, position, depth, nodes) do
    cond do
      depth > @max_depth ->
        {:error, :depth_limit}

      nodes >= @max_nodes ->
        {:error, :node_limit}

      true ->
        with {:ok, tag, position} <- read_uint(binary, position, 1) do
          {:ok, tag, position, nodes + 1}
        end
    end
  end

  defp atom_length(binary, position, tag) when tag in [115, 119],
    do: read_uint(binary, position, 1)

  defp atom_length(binary, position, tag) when tag in [100, 118],
    do: read_uint(binary, position, 2)

  defp decode_atom(tag, bytes) when tag in [100, 115] do
    decode_latin1(bytes)
  end

  defp decode_atom(_tag, bytes), do: decode_utf8(bytes)

  defp decode_latin1(bytes) do
    case :unicode.characters_to_binary(bytes, :latin1, :utf8) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, :invalid_encoding}
    end
  end

  defp decode_utf8(bytes) do
    if String.valid?(bytes), do: {:ok, bytes}, else: {:error, :invalid_encoding}
  end

  defp read_signed_int(binary, position) do
    with {:ok, bytes, position} <- read_bytes(binary, position, 4, 4) do
      <<value::signed-big-32>> = bytes
      {:ok, value, position}
    end
  end

  defp read_uint(binary, position, width) when width in [1, 2, 4] do
    with {:ok, bytes, position} <- read_bytes(binary, position, width, width) do
      value = :binary.decode_unsigned(bytes, :big)
      {:ok, value, position}
    end
  end

  defp read_bytes(binary, position, length, max_length)
       when is_integer(length) and length >= 0 and length <= max_length do
    if position + length <= byte_size(binary) do
      {:ok, binary_part(binary, position, length), position + length}
    else
      {:error, :truncated}
    end
  end

  defp read_bytes(_binary, _position, _length, _max_length), do: {:error, :truncated}

  defp advance(binary, position, length)
       when is_integer(length) and length >= 0 and position + length <= byte_size(binary),
       do: {:ok, position + length}

  defp advance(_binary, _position, _length), do: {:error, :truncated}

  defp advance_with_nodes(binary, position, length, nodes) do
    with {:ok, position} <- advance(binary, position, length) do
      {:ok, position, nodes}
    end
  end
end
