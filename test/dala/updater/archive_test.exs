defmodule Dala.Updater.ArchiveTest do
  use ExUnit.Case, async: true

  alias Dala.Updater.Archive

  @zip_central_signature <<0x50, 0x4B, 0x01, 0x02>>

  setup do
    directory =
      Path.join(System.tmp_dir!(), "dala-archive-safety-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf(directory) end)
    {:ok, directory: directory}
  end

  test "accepts ordinary release-style ZIP and TAR entries", %{directory: directory} do
    zip = Path.join(directory, "release.zip")
    tar = Path.join(directory, "release.tar.gz")

    write_zip(zip, [{"bin/dala.bat", "@echo off\r\n"}, {"lib/dala.app", "app"}])
    write_tar(tar, [{~c"./bin/dala", "#!/bin/sh\n"}, {~c"./releases/start_erl.data", "erts v\n"}])

    assert Archive.validate(zip, "windows-x86_64") == :ok
    assert Archive.validate(tar, "linux-x86_64") == :ok
  end

  test "rejects ZIP absolute, parent, drive and UNC paths", %{directory: directory} do
    paths = [
      "../escape",
      "safe/../escape",
      "/absolute",
      "\\absolute",
      "C:/escape",
      "\\\\server\\share\\escape"
    ]

    Enum.each(paths, fn path ->
      archive = Path.join(directory, "#{System.unique_integer([:positive])}.zip")
      write_zip_with_raw_name(archive, path)

      assert {:error, message} = Archive.validate(archive, "windows-x86_64")
      assert message =~ "unsafe entry"
    end)
  end

  test "rejects Windows-special ZIP segments and accepts a directory suffix", %{
    directory: directory
  } do
    invalid_paths = [
      "safe//file",
      "safe/./file",
      "safe/file:stream",
      "safe/file.",
      "safe/file ",
      "safe/CON.txt",
      "safe/CON .txt",
      "safe/CONIN$.txt",
      "safe/CONOUT$.txt",
      "safe/CLOCK$.json",
      "safe/COM1.bin",
      "safe/LPT9",
      "safe/bad<name",
      "safe/bad>name",
      "safe/bad\"name",
      "safe/bad|name",
      "safe/bad?name",
      "safe/bad*name",
      "safe/bad\u0001name",
      "safe\\"
    ]

    invalid_paths =
      invalid_paths ++
        for suffix <- [<<0xC2, 0xB9>>, <<0xC2, 0xB2>>, <<0xC2, 0xB3>>],
            prefix <- ["COM", "LPT"] do
          "safe/" <> prefix <> suffix <> ".bin"
        end

    for path <- invalid_paths do
      archive = Path.join(directory, "invalid-#{System.unique_integer([:positive])}.zip")
      write_zip_with_raw_name(archive, path)

      assert {:error, message} = Archive.validate(archive, "windows-x86_64")
      assert message =~ "unsafe entry"
    end

    directory_archive = Path.join(directory, "directory-entry.zip")
    write_zip_with_raw_name(directory_archive, "safe/")
    assert Archive.validate(directory_archive, "windows-x86_64") == :ok

    ordinary_device_like_archive = Path.join(directory, "ordinary-device-like.zip")

    write_zip(ordinary_device_like_archive, [
      {"safe/COM0.txt", "payload"},
      {"safe/LPT0", "payload"}
    ])

    assert Archive.validate(ordinary_device_like_archive, "windows-x86_64") == :ok
  end

  test "rejects ZIP local-header paths even when the central name is safe", %{
    directory: directory
  } do
    archive = Path.join(directory, "local-name.zip")
    write_zip_with_local_name(archive, "safe-file", "../escape")

    assert {:error, message} = Archive.validate(archive, "windows-x86_64")
    assert message =~ "unsafe entry"
  end

  test "rejects ZIP local compression metadata that disagrees with the central entry", %{
    directory: directory
  } do
    cases = [
      {"method", 8, <<99, 0>>},
      {"flags", 6, <<8, 0>>},
      {"compressed-size", 18, <<0xFF, 0xFF, 0xFF, 0x7F>>},
      {"uncompressed-size", 22, <<0xFF, 0xFF, 0xFF, 0x7F>>},
      {"crc", 14, <<0, 0, 0, 0>>}
    ]

    for {label, offset, replacement} <- cases do
      archive = Path.join(directory, "local-metadata-#{label}.zip")
      write_zip_with_local_field(archive, offset, replacement)

      assert {:error, message} = Archive.validate(archive, "windows-x86_64")
      assert message =~ "invalid ZIP metadata"
    end
  end

  test "rejects ZIP entries using unsupported or encrypted methods", %{directory: directory} do
    unsupported = Path.join(directory, "unsupported-method.zip")
    write_zip_with_central_field(unsupported, 10, <<99, 0>>)

    assert {:error, message} = Archive.validate(unsupported, "windows-x86_64")
    assert message =~ "invalid ZIP metadata"

    encrypted = Path.join(directory, "encrypted.zip")
    write_zip_with_central_field(encrypted, 8, <<1, 0>>)

    assert {:error, message} = Archive.validate(encrypted, "windows-x86_64")
    assert message =~ "invalid ZIP metadata"
  end

  test "rejects ZIP64 entry size sentinels", %{directory: directory} do
    for {label, central_offset, local_offset} <- [
          {"compressed", 20, 18},
          {"uncompressed", 24, 22}
        ] do
      archive = Path.join(directory, "zip64-#{label}.zip")
      write_zip_with_central_and_local_field(archive, central_offset, local_offset)

      assert {:error, message} = Archive.validate(archive, "windows-x86_64")
      assert message =~ "invalid ZIP metadata"
    end
  end

  test "rejects malformed ZIP extra-field TLVs", %{directory: directory} do
    for location <- [:local, :central] do
      archive = Path.join(directory, "malformed-extra-#{location}.zip")
      write_zip_with_malformed_extra(archive, location)

      assert {:error, message} = Archive.validate(archive, "windows-x86_64")
      assert message =~ "invalid ZIP metadata"
    end
  end

  test "rejects local UT payloads that the extractor cannot parse", %{directory: directory} do
    archive = Path.join(directory, "invalid-local-ut.zip")
    write_zip_with_local_ut_flags(archive, 0)

    assert {:error, message} = Archive.validate(archive, "windows-x86_64")
    assert message =~ "invalid ZIP metadata"
  end

  test "rejects central UT payloads that the extractor cannot parse", %{directory: directory} do
    archive = Path.join(directory, "invalid-central-ut.zip")
    write_zip_with_central_ut_flags(archive, 0)

    assert {:error, message} = Archive.validate(archive, "windows-x86_64")
    assert message =~ "invalid ZIP metadata"
  end

  test "rejects malformed ZIP ux UID/GID payloads", %{directory: directory} do
    archive = Path.join(directory, "invalid-ux.zip")
    write_zip_with_local_ux_uid_size(archive, 255)

    assert {:error, message} = Archive.validate(archive, "windows-x86_64")
    assert message =~ "invalid ZIP metadata"

    short_version = Path.join(directory, "invalid-ux-version.zip")
    write_zip_with_local_ux_version(short_version, 2)

    assert {:error, message} = Archive.validate(short_version, "windows-x86_64")
    assert message =~ "invalid ZIP metadata"
  end

  test "rejects Windows duplicate ZIP names after case and separator normalization", %{
    directory: directory
  } do
    archive = Path.join(directory, "duplicate-names.zip")
    write_zip(archive, [{"safe/file", "first"}, {"SAFE\\FILE", "second"}])

    assert {:error, message} = Archive.validate(archive, "windows-x86_64")
    assert message =~ "duplicate Windows path"
  end

  test "uses Windows simple Unicode casing for duplicate ZIP names", %{directory: directory} do
    collision = Path.join(directory, "unicode-collision.zip")
    write_zip(collision, [{"safe/σ", "first"}, {"SAFE/ς", "second"}])

    assert {:error, message} = Archive.validate(collision, "windows-x86_64")
    assert message =~ "duplicate Windows path"

    distinct = Path.join(directory, "unicode-distinct.zip")

    write_zip(distinct, [
      {"safe/ß", "sharp-s"},
      {"safe/SS", "two-letters"},
      {"safe/İ", "capital-dotted-i"},
      {"safe/i\u0307", "i-and-combining-dot"}
    ])

    assert Archive.validate(distinct, "windows-x86_64") == :ok

    extended = Path.join(directory, "unicode-extended-collision.zip")
    write_zip(extended, [{"safe/\u1f80", "small"}, {"SAFE/\u1f88", "title"}])

    assert {:error, message} = Archive.validate(extended, "windows-x86_64")
    assert message =~ "duplicate Windows path"
  end

  test "rejects ZIP symlink and reparse attributes", %{directory: directory} do
    for {label, attributes} <- [symlink: 0xA1FF0000, reparse: 0x400] do
      archive = Path.join(directory, "#{label}.zip")
      write_zip_with_attributes(archive, attributes)

      assert {:error, message} = Archive.validate(archive, "windows-x86_64")
      assert message =~ "unsafe entry"
    end
  end

  test "rejects TAR absolute, parent and Windows drive paths", %{directory: directory} do
    paths = ["../escape", "/absolute", "C:/escape", "\\absolute"]

    Enum.each(paths, fn path ->
      archive = Path.join(directory, "#{System.unique_integer([:positive])}.tar.gz")
      write_tar(archive, [{String.to_charlist(path), "escape"}])

      assert {:error, message} = Archive.validate(archive, "linux-x86_64")
      assert message =~ "unsafe entry"
    end)
  end

  test "rejects TAR symlink, hardlink and device entries", %{directory: directory} do
    for {label, type} <- [symlink: ?2, hardlink: ?1, device: ?3] do
      archive = Path.join(directory, "#{label}.tar.gz")
      write_tar(archive, [{~c"entry", "payload"}])
      patch_tar_type(archive, type, "target")

      assert {:error, message} = Archive.validate(archive, "linux-x86_64")
      assert message =~ "unsafe entry"
    end
  end

  defp write_zip(path, entries) do
    entries = Enum.map(entries, fn {name, body} -> {String.to_charlist(name), body} end)
    {:ok, {_name, archive}} = :zip.create(~c"release.zip", entries, [:memory])
    File.write!(path, archive)
  end

  defp write_zip_with_raw_name(path, name) do
    placeholder = String.duplicate("a", byte_size(name))

    {:ok, {_name, archive}} =
      :zip.create(~c"release.zip", [{String.to_charlist(placeholder), "payload"}], [:memory])

    archive = replace_zip_names(archive, placeholder, name)
    File.write!(path, archive)
  end

  defp write_zip_with_local_name(path, central_name, local_name) do
    assert byte_size(central_name) == byte_size(local_name)

    {:ok, {_name, archive}} =
      :zip.create(~c"release.zip", [{String.to_charlist(central_name), "payload"}], [:memory])

    [{offset, length} | _] = :binary.matches(archive, central_name)

    archive =
      binary_part(archive, 0, offset) <>
        local_name <>
        binary_part(archive, offset + length, byte_size(archive) - offset - length)

    File.write!(path, archive)
  end

  defp write_zip_with_attributes(path, attributes) do
    {:ok, {_name, archive}} = :zip.create(~c"release.zip", [{~c"safe", "payload"}], [:memory])
    [{central_offset, _length}] = :binary.matches(archive, @zip_central_signature)
    archive = put_bytes(archive, central_offset + 38, <<attributes::little-32>>)
    File.write!(path, archive)
  end

  defp write_zip_with_local_field(path, offset, replacement) do
    {:ok, {_name, archive}} = :zip.create(~c"release.zip", [{~c"safe", "payload"}], [:memory])
    File.write!(path, put_bytes(archive, offset, replacement))
  end

  defp write_zip_with_central_field(path, offset, replacement) do
    {:ok, {_name, archive}} = :zip.create(~c"release.zip", [{~c"safe", "payload"}], [:memory])
    [{central_offset, _length}] = :binary.matches(archive, @zip_central_signature)
    File.write!(path, put_bytes(archive, central_offset + offset, replacement))
  end

  defp write_zip_with_central_and_local_field(path, central_offset, local_offset) do
    {:ok, {_name, archive}} = :zip.create(~c"release.zip", [{~c"safe", "payload"}], [:memory])
    [{central_start, _length}] = :binary.matches(archive, @zip_central_signature)
    sentinel = <<0xFF, 0xFF, 0xFF, 0xFF>>
    archive = put_bytes(archive, central_start + central_offset, sentinel)
    archive = put_bytes(archive, local_offset, sentinel)
    File.write!(path, archive)
  end

  defp write_zip_with_malformed_extra(path, :local) do
    {:ok, {_name, archive}} =
      :zip.create(~c"release.zip", [{~c"safe", "payload"}], [
        :memory,
        {:extra, [:extended_timestamp]}
      ])

    # The first local extra field starts after the fixed header and filename;
    # replace its two-byte payload length with an impossible value.
    File.write!(path, put_bytes(archive, 30 + 4 + 2, <<0xFF, 0xFF>>))
  end

  defp write_zip_with_malformed_extra(path, :central) do
    {:ok, {_name, archive}} =
      :zip.create(~c"release.zip", [{~c"safe", "payload"}], [
        :memory,
        {:extra, [:extended_timestamp]}
      ])

    [{central_offset, _length}] = :binary.matches(archive, @zip_central_signature)

    # The central header has a 46-byte fixed prefix before the filename.
    File.write!(path, put_bytes(archive, central_offset + 46 + 4 + 2, <<0xFF, 0xFF>>))
  end

  defp write_zip_with_local_ut_flags(path, flags) do
    {:ok, {_name, archive}} =
      :zip.create(~c"release.zip", [{~c"safe", "payload"}], [
        :memory,
        {:extra, [:extended_timestamp]}
      ])

    # Local fixed header (30) + filename (4) + UT tag/length (4).
    File.write!(path, put_bytes(archive, 30 + 4 + 4, <<flags>>))
  end

  defp write_zip_with_central_ut_flags(path, flags) do
    {:ok, {_name, archive}} =
      :zip.create(~c"release.zip", [{~c"safe", "payload"}], [
        :memory,
        {:extra, [:extended_timestamp]}
      ])

    [{central_offset, _length}] = :binary.matches(archive, @zip_central_signature)

    # Central fixed header (46) + filename (4) + UT tag/length (4).
    File.write!(path, put_bytes(archive, central_offset + 46 + 4 + 4, <<flags>>))
  end

  defp write_zip_with_local_ux_uid_size(path, uid_size) do
    {:ok, {_name, archive}} =
      :zip.create(~c"release.zip", [{~c"safe", "payload"}], [
        :memory,
        {:extra, [:uid_gid]}
      ])

    # Local fixed header (30) + filename (4) + ux tag/length (4) + version (1).
    File.write!(path, put_bytes(archive, 30 + 4 + 4 + 1, <<uid_size>>))
  end

  defp write_zip_with_local_ux_version(path, version) do
    {:ok, {_name, archive}} =
      :zip.create(~c"release.zip", [{~c"safe", "payload"}], [
        :memory,
        {:extra, [:uid_gid]}
      ])

    # Make the ux payload only one byte long. Unknown versions are ignored by
    # the extractor when well-formed, but this truncated payload is invalid.
    archive = put_bytes(archive, 30 + 4 + 2, <<1, 0>>)
    archive = put_bytes(archive, 30 + 4 + 4, <<version>>)
    File.write!(path, archive)
  end

  defp replace_zip_names(archive, old, new) do
    assert byte_size(old) == byte_size(new)

    archive
    |> :binary.matches(old)
    |> Enum.reverse()
    |> Enum.reduce(archive, fn {offset, length}, binary ->
      binary_part(binary, 0, offset) <>
        new <>
        binary_part(binary, offset + length, byte_size(binary) - offset - length)
    end)
  end

  defp write_tar(path, entries) do
    assert :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
  end

  defp patch_tar_type(path, type, linkname) do
    raw = path |> File.read!() |> :zlib.gunzip()
    <<header::binary-size(512), _payload_block::binary-size(512), rest::binary>> = raw

    header = put_bytes(header, 148, "        ")
    header = put_bytes(header, 124, :binary.copy("0", 11) <> <<0>>)
    header = put_bytes(header, 156, <<type>>)
    linkname = linkname <> :binary.copy(<<0>>, 100 - byte_size(linkname))
    header = put_bytes(header, 157, linkname)
    checksum = header |> :binary.bin_to_list() |> Enum.sum() |> Integer.to_string(8)
    checksum = String.pad_leading(checksum, 6, "0") <> <<0, 32>>
    raw = put_bytes(header, 148, checksum) <> rest
    File.write!(path, :zlib.gzip(raw))
  end

  defp put_bytes(binary, offset, replacement) do
    size = byte_size(replacement)

    binary_part(binary, 0, offset) <>
      replacement <>
      binary_part(binary, offset + size, byte_size(binary) - offset - size)
  end
end
