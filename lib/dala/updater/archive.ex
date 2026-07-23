defmodule Dala.Updater.Archive do
  @moduledoc false

  import Bitwise, only: [band: 2, bsr: 2]

  @zip_eocd_signature <<0x50, 0x4B, 0x05, 0x06>>
  @zip_central_signature 0x02014B50
  @zip_local_signature 0x04034B50
  @zip64_extra_field 0x0001
  @zip_extended_timestamp_extra 0x5455
  @zip_unix3_extra 0x7875
  @zip_eocd_size 22
  @zip_max_comment_size 65_535
  @zip64_16 0xFFFF
  @zip64_32 0xFFFFFFFF
  @unix_file_type_mask 0xF000
  @unix_regular 0x8000
  @unix_directory 0x4000
  @windows_device_attribute 0x40
  @windows_reparse_attribute 0x400
  @windows_device_names ~w(
                           CON PRN AUX NUL CONIN$ CONOUT$ CLOCK$ COM1 COM2 COM3 COM4 COM5 COM6 COM7 COM8 COM9
                           LPT1 LPT2 LPT3 LPT4 LPT5 LPT6 LPT7 LPT8 LPT9
                         )
  @windows_reserved_superscript_names for prefix <- ~w(COM LPT),
                                          suffix <- [
                                            <<0xC2, 0xB9>>,
                                            <<0xC2, 0xB2>>,
                                            <<0xC2, 0xB3>>
                                          ],
                                          do: prefix <> suffix
  @windows_forbidden_path_bytes Enum.to_list(0..31) ++ ~c"<>\"|?*"

  @spec validate(Path.t(), String.t()) :: :ok | {:error, String.t()}
  def validate(path, "windows-x86_64"), do: validate_zip(path)
  def validate(path, _unix_platform), do: validate_tar(path)

  defp validate_zip(path) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          validate_open_zip(file)
        after
          :file.close(file)
        end

      {:error, reason} ->
        archive_read_error(reason)
    end
  rescue
    error -> archive_read_error(error)
  end

  defp validate_open_zip(file) do
    with {:ok, archive_size} <- :file.position(file, :eof),
         {:ok, tail} <- read_zip_tail(file, archive_size),
         {:ok, directory} <- find_zip_directory(tail, archive_size),
         {:ok, central} <-
           read_exact(file, directory.offset, directory.size, "ZIP central directory"),
         {:ok, entries} <- parse_zip_entries(central, directory.entries, []),
         :ok <- validate_zip_entries(file, archive_size, directory.offset, entries) do
      :ok
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> invalid_zip(reason)
      _ -> invalid_zip(:malformed)
    end
  end

  defp read_zip_tail(file, archive_size) when archive_size >= @zip_eocd_size do
    length = min(archive_size, @zip_eocd_size + @zip_max_comment_size)
    read_exact(file, archive_size - length, length, "ZIP end record")
  end

  defp read_zip_tail(_file, _archive_size), do: invalid_zip(:missing_end_record)

  defp find_zip_directory(tail, archive_size) do
    candidate =
      tail
      |> :binary.matches(@zip_eocd_signature)
      |> Enum.reverse()
      |> Enum.find_value(fn {offset, _length} ->
        rest = binary_part(tail, offset, byte_size(tail) - offset)

        case rest do
          <<@zip_eocd_signature, _disk::little-16, _directory_disk::little-16,
            _disk_entries::little-16, _entries::little-16, _size::little-32,
            _directory_offset::little-32, comment_size::little-16,
            _comment::binary-size(comment_size)>> ->
            {offset, rest}

          _ ->
            nil
        end
      end)

    case candidate do
      {tail_offset,
       <<@zip_eocd_signature, disk::little-16, directory_disk::little-16, disk_entries::little-16,
         entries::little-16, size::little-32, offset::little-32, _comment_size::little-16,
         _comment::binary>>} ->
        eocd_offset = archive_size - byte_size(tail) + tail_offset

        cond do
          disk != 0 or directory_disk != 0 or disk_entries != entries ->
            invalid_zip(:multi_disk_archive)

          entries == @zip64_16 or size == @zip64_32 or offset == @zip64_32 ->
            invalid_zip(:zip64_not_supported)

          offset + size != eocd_offset ->
            invalid_zip(:invalid_central_directory_bounds)

          true ->
            {:ok, %{entries: entries, offset: offset, size: size}}
        end

      nil ->
        invalid_zip(:missing_end_record)
    end
  end

  defp parse_zip_entries(<<>>, 0, entries), do: {:ok, Enum.reverse(entries)}
  defp parse_zip_entries(_remaining, 0, _entries), do: invalid_zip(:trailing_central_data)

  defp parse_zip_entries(binary, remaining_count, entries) when remaining_count > 0 do
    case binary do
      <<@zip_central_signature::little-32, made_by::little-16, _needed::little-16,
        flags::little-16, method::little-16, _time::little-16, _date::little-16, crc32::little-32,
        compressed_size::little-32, uncompressed_size::little-32, name_size::little-16,
        extra_size::little-16, comment_size::little-16, disk::little-16,
        _internal_attributes::little-16, external_attributes::little-32, local_offset::little-32,
        rest::binary>> ->
        variable_size = name_size + extra_size + comment_size

        if byte_size(rest) >= variable_size and name_size > 0 and disk == 0 and
             local_offset != @zip64_32 do
          <<name::binary-size(name_size), _extra::binary-size(extra_size),
            _comment::binary-size(comment_size), remaining::binary>> = rest

          extra = binary_part(rest, name_size, extra_size)

          case validate_zip_extra_fields(extra) do
            :ok ->
              entry = %{
                external_attributes: external_attributes,
                flags: flags,
                method: method,
                crc32: crc32,
                compressed_size: compressed_size,
                uncompressed_size: uncompressed_size,
                local_offset: local_offset,
                name: name,
                system: bsr(made_by, 8)
              }

              parse_zip_entries(remaining, remaining_count - 1, [entry | entries])

            {:error, _reason} ->
              invalid_zip(:invalid_central_extra_fields)
          end
        else
          invalid_zip(:invalid_central_entry)
        end

      _ ->
        invalid_zip(:invalid_central_entry)
    end
  end

  defp validate_zip_entries(file, archive_size, central_offset, entries) do
    Enum.reduce_while(entries, MapSet.new(), fn entry, seen ->
      result =
        with :ok <- validate_entry_path(entry.name, true),
             key = normalized_windows_entry_name(entry.name),
             false <- MapSet.member?(seen, key),
             :ok <- validate_zip_entry_type(entry),
             :ok <- validate_zip_compression(entry),
             {:ok, local_name} <-
               read_zip_local_entry(file, archive_size, central_offset, entry),
             :ok <- validate_entry_path(local_name, true),
             true <- local_name == entry.name do
          {:ok, key}
        else
          true -> unsafe_entry(entry.name, "duplicate Windows path")
          false -> invalid_zip(:local_and_central_names_differ)
          {:error, _message} = error -> error
        end

      case result do
        {:ok, key} -> {:cont, MapSet.put(seen, key)}
        {:error, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, _message} = error -> error
    end
  end

  defp normalized_windows_entry_name(name) do
    name
    |> String.replace("\\", "/")
    |> String.trim_trailing("/")
    |> Dala.Paths.comparison_key_for_os({:win32, :nt})
  end

  defp validate_zip_compression(%{method: method, flags: flags}) do
    cond do
      band(flags, 1) != 0 -> invalid_zip(:encrypted_entry)
      method not in [0, 8] -> invalid_zip(:unsupported_compression_method)
      true -> :ok
    end
  end

  defp read_zip_local_entry(file, archive_size, central_offset, entry)
       when entry.local_offset + 30 <= archive_size do
    offset = entry.local_offset

    with {:ok,
          <<@zip_local_signature::little-32, _needed::little-16, flags::little-16,
            method::little-16, _time::little-16, _date::little-16, crc32::little-32,
            compressed_size::little-32, uncompressed_size::little-32, name_size::little-16,
            extra_size::little-16>>} <- read_exact(file, offset, 30, "ZIP local header"),
         true <- name_size > 0 and offset + 30 + name_size + extra_size <= archive_size,
         {:ok, variable} <-
           read_exact(
             file,
             offset + 30,
             name_size + extra_size,
             "ZIP local filename and extra fields"
           ),
         <<name::binary-size(name_size), extra::binary-size(extra_size)>> = variable,
         :ok <- validate_zip_extra_fields(extra),
         :ok <-
           validate_local_zip_metadata(
             entry,
             %{
               flags: flags,
               method: method,
               crc32: crc32,
               compressed_size: compressed_size,
               uncompressed_size: uncompressed_size
             },
             offset + 30 + name_size + extra_size,
             central_offset,
             archive_size
           ) do
      {:ok, name}
    else
      _ -> invalid_zip(:invalid_local_entry)
    end
  end

  defp read_zip_local_entry(_file, _archive_size, _central_offset, _entry),
    do: invalid_zip(:invalid_local_entry)

  defp validate_local_zip_metadata(entry, local, data_offset, central_offset, archive_size) do
    descriptor_size = if band(entry.flags, 8) != 0, do: 12, else: 0
    data_end = data_offset + entry.compressed_size + descriptor_size

    cond do
      local.flags != entry.flags ->
        invalid_zip(:local_and_central_flags_differ)

      local.method != entry.method ->
        invalid_zip(:local_and_central_methods_differ)

      band(entry.flags, 8) == 0 and
          (local.crc32 != entry.crc32 or
             local.compressed_size != entry.compressed_size or
             local.uncompressed_size != entry.uncompressed_size) ->
        invalid_zip(:local_and_central_sizes_differ)

      band(entry.flags, 8) != 0 and
          not descriptor_field_matches?(local.crc32, entry.crc32) ->
        invalid_zip(:invalid_local_crc)

      band(entry.flags, 8) != 0 and
          not descriptor_field_matches?(local.compressed_size, entry.compressed_size) ->
        invalid_zip(:invalid_local_compressed_size)

      band(entry.flags, 8) != 0 and
          not descriptor_field_matches?(local.uncompressed_size, entry.uncompressed_size) ->
        invalid_zip(:invalid_local_uncompressed_size)

      data_offset > central_offset or data_end > central_offset or
          data_end > archive_size ->
        invalid_zip(:invalid_local_data_bounds)

      true ->
        :ok
    end
  end

  # ZIP writers using a data descriptor normally leave these local fields at
  # zero; a few writers repeat the central values instead. Both forms are
  # safe because Erlang's extractor uses the central values when bit 3 is set.
  defp descriptor_field_matches?(0, _central), do: true
  defp descriptor_field_matches?(value, central), do: value == central

  defp validate_zip_extra_fields(<<>>), do: :ok

  defp validate_zip_extra_fields(<<tag::little-16, size::little-16, rest::binary>>)
       when byte_size(rest) >= size do
    <<payload::binary-size(size), remaining::binary>> = rest

    with :ok <- validate_zip_extra_payload(tag, payload),
         :ok <- validate_zip_extra_fields(remaining) do
      :ok
    end
  end

  defp validate_zip_extra_fields(_extra), do: {:error, :malformed_extra_fields}

  # Erlang's extractor interprets these extensions instead of treating them
  # as opaque bytes. Validate their payload shape before extraction so a
  # structurally valid TLV cannot trigger a parser badmatch.
  defp validate_zip_extra_payload(@zip_extended_timestamp_extra, <<flags, timestamps::binary>>) do
    expected_size =
      Enum.reduce([1, 2, 4], 0, fn mask, size ->
        if band(flags, mask) != 0, do: size + 4, else: size
      end)

    if byte_size(timestamps) == expected_size do
      :ok
    else
      {:error, :invalid_extended_timestamp}
    end
  end

  defp validate_zip_extra_payload(@zip_extended_timestamp_extra, _payload),
    do: {:error, :invalid_extended_timestamp}

  defp validate_zip_extra_payload(@zip_unix3_extra, <<1, uid_size, rest::binary>>) do
    case rest do
      <<_uid::binary-size(uid_size), gid_size, _gid::binary-size(gid_size)>> ->
        :ok

      _ ->
        {:error, :invalid_unix3}
    end
  end

  defp validate_zip_extra_payload(@zip_unix3_extra, <<version, rest::binary>>)
       when version != 1 and byte_size(rest) > 0,
       do: :ok

  defp validate_zip_extra_payload(@zip_unix3_extra, _payload),
    do: {:error, :invalid_unix3}

  defp validate_zip_extra_payload(@zip64_extra_field, payload) do
    # ZIP64 values are a sequence of optional 8-byte sizes/offsets followed
    # by an optional 4-byte disk number. Without a sentinel in the header we
    # cannot determine which fields are present, but every valid sequence is
    # non-empty, at most 28 bytes, and aligned to a 4-byte field boundary.
    if byte_size(payload) in 4..28 and rem(byte_size(payload), 4) == 0 do
      :ok
    else
      {:error, :invalid_zip64_extra}
    end
  end

  defp validate_zip_extra_payload(_tag, _payload), do: :ok

  defp validate_zip_entry_type(entry) do
    attributes = entry.external_attributes
    unix_type = attributes |> bsr(16) |> band(@unix_file_type_mask)
    windows_attributes = band(attributes, 0xFFFF)

    cond do
      band(windows_attributes, @windows_reparse_attribute) != 0 ->
        unsafe_entry(entry.name, "Windows reparse points are not allowed")

      band(windows_attributes, @windows_device_attribute) != 0 ->
        unsafe_entry(entry.name, "Windows device entries are not allowed")

      unix_type in [0, @unix_regular, @unix_directory] ->
        :ok

      true ->
        unsafe_entry(entry.name, "link and device entry types are not allowed")
    end
  end

  defp validate_tar(path) do
    case :erl_tar.table(String.to_charlist(path), [:compressed, :verbose]) do
      {:ok, entries} -> validate_tar_entries(entries)
      {:error, reason} -> archive_read_error(reason)
    end
  rescue
    error -> archive_read_error(error)
  end

  defp validate_tar_entries(entries) do
    Enum.reduce_while(entries, :ok, fn
      {name, type, _size, _mtime, _mode, _uid, _gid}, :ok ->
        with {:ok, binary_name} <- archive_name_to_binary(name),
             :ok <- validate_entry_path(binary_name, false),
             :ok <- validate_tar_entry_type(binary_name, type) do
          {:cont, :ok}
        else
          {:error, _message} = error -> {:halt, error}
        end

      _entry, :ok ->
        {:halt, invalid_tar(:invalid_entry_metadata)}
    end)
  end

  defp validate_tar_entry_type(_name, type) when type in [:regular, :directory], do: :ok

  defp validate_tar_entry_type(name, _type),
    do: unsafe_entry(name, "link and device entry types are not allowed")

  defp archive_name_to_binary(name) when is_binary(name), do: {:ok, name}

  defp archive_name_to_binary(name) when is_list(name) do
    case :unicode.characters_to_binary(name) do
      binary when is_binary(binary) -> {:ok, binary}
      _ -> unsafe_entry(inspect(name), "filename encoding is invalid")
    end
  end

  defp archive_name_to_binary(name),
    do: unsafe_entry(inspect(name), "filename encoding is invalid")

  defp validate_entry_path(name, windows?) when is_binary(name) do
    segments =
      :binary.split(name, :binary.compile_pattern([<<"/">>, <<"\\">>]), [:global])

    cond do
      name == "" ->
        unsafe_entry(name, "empty paths are not allowed")

      :binary.match(name, <<0>>) != :nomatch ->
        unsafe_entry(name, "NUL bytes are not allowed")

      not String.valid?(name) ->
        unsafe_entry(name, "filename encoding is invalid")

      absolute_path?(name) ->
        unsafe_entry(name, "absolute paths are not allowed")

      Enum.any?(segments, &(&1 == "..")) ->
        unsafe_entry(name, "parent path segments are not allowed")

      windows? and String.ends_with?(name, "\\") ->
        unsafe_entry(name, "Windows directory entries must use a forward-slash suffix")

      windows? and invalid_windows_entry_segments?(segments) ->
        unsafe_entry(name, "Windows-special paths are not allowed")

      true ->
        :ok
    end
  end

  defp absolute_path?(<<first, _rest::binary>>) when first in [?/, ?\\], do: true

  defp absolute_path?(<<letter, ?:, _rest::binary>>)
       when letter in ?a..?z or letter in ?A..?Z,
       do: true

  defp absolute_path?(_name), do: false

  defp invalid_windows_entry_segments?(segments) do
    last_index = length(segments) - 1

    segments
    |> Enum.with_index()
    |> Enum.any?(fn {segment, index} ->
      (segment == "" and index != last_index) or
        segment == "." or
        String.contains?(segment, ":") or
        String.ends_with?(segment, [" ", "."]) or
        Enum.any?(:binary.bin_to_list(segment), &(&1 in @windows_forbidden_path_bytes)) or
        windows_device_segment?(segment)
    end)
  end

  defp windows_device_segment?(segment) do
    basename =
      segment
      |> String.split(".", parts: 2)
      |> hd()
      |> trim_windows_ignored_suffix()
      |> String.upcase()

    basename in @windows_device_names or basename in @windows_reserved_superscript_names
  end

  defp trim_windows_ignored_suffix(""), do: ""

  defp trim_windows_ignored_suffix(segment) do
    if :binary.last(segment) in [?., ?\s] do
      segment
      |> binary_part(0, byte_size(segment) - 1)
      |> trim_windows_ignored_suffix()
    else
      segment
    end
  end

  defp read_exact(file, offset, length, label) do
    case :file.pread(file, offset, length) do
      {:ok, data} when byte_size(data) == length -> {:ok, data}
      _ -> {:error, "release archive has invalid #{label}"}
    end
  end

  defp unsafe_entry(name, reason) do
    rendered = inspect(name, binaries: :as_strings, limit: 20, printable_limit: 160)
    {:error, "release archive contains unsafe entry #{rendered}: #{reason}"}
  end

  defp invalid_zip(reason),
    do: {:error, "release archive has invalid ZIP metadata: #{inspect(reason)}"}

  defp invalid_tar(reason),
    do: {:error, "release archive has invalid TAR metadata: #{inspect(reason)}"}

  defp archive_read_error(reason),
    do: {:error, "could not inspect release archive: #{inspect(reason)}"}
end
