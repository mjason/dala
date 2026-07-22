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

  test "rejects ZIP local-header paths even when the central name is safe", %{
    directory: directory
  } do
    archive = Path.join(directory, "local-name.zip")
    write_zip_with_local_name(archive, "safe-file", "../escape")

    assert {:error, message} = Archive.validate(archive, "windows-x86_64")
    assert message =~ "unsafe entry"
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
