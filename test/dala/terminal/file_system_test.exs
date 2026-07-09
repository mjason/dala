defmodule Dala.Terminal.FileSystemTest do
  use ExUnit.Case, async: true

  setup do
    dir = Path.join(System.tmp_dir!(), "dala-fs-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_file(path, content) do
    Dala.Terminal.FileSystem
    |> Ash.ActionInput.for_action(:write_file, %{path: path, content: content})
    |> Ash.run_action()
  end

  defp read_file(path) do
    Dala.Terminal.FileSystem
    |> Ash.ActionInput.for_action(:read_file, %{path: path})
    |> Ash.run_action()
  end

  test "overwrites an existing file and returns the new size", %{dir: dir} do
    path = Path.join(dir, "a.txt")
    File.write!(path, "old content\n")

    assert {:ok, %{path: ^path, size: size}} = write_file(path, "new text")
    assert size == byte_size("new text")
    assert File.read!(path) == "new text"
  end

  test "creates a new file in an existing directory", %{dir: dir} do
    path = Path.join(dir, "fresh.md")

    assert {:ok, %{size: 5}} = write_file(path, "hello")
    assert File.read!(path) == "hello"
  end

  test "round-trips content through read_file", %{dir: dir} do
    path = Path.join(dir, "code.ex")
    content = "defmodule X do\n  def hi, do: :ok\nend\n"

    assert {:ok, _} = write_file(path, content)
    assert {:ok, %{content: ^content, binary: false, truncated: false}} = read_file(path)
  end

  test "refuses to write to a directory", %{dir: dir} do
    assert {:error, error} = write_file(dir, "nope")
    assert Exception.message(error) =~ "is a directory"
  end

  test "refuses to write into a nonexistent directory", %{dir: dir} do
    path = Path.join(dir, "missing/deep/file.txt")
    assert {:error, error} = write_file(path, "x")
    assert Exception.message(error) =~ "cannot write"
  end

  test "rejects content over the size cap", %{dir: dir} do
    path = Path.join(dir, "big.txt")
    huge = String.duplicate("a", 10 * 1024 * 1024 + 1)

    assert {:error, error} = write_file(path, huge)
    assert Exception.message(error) =~ "too large"
    refute File.exists?(path)
  end

  defp save_pasted_file(name, content_base64) do
    Dala.Terminal.FileSystem
    |> Ash.ActionInput.for_action(:save_pasted_file, %{name: name, content_base64: content_base64})
    |> Ash.run_action()
  end

  test "save_pasted_file stores the decoded bytes and returns an absolute path" do
    bytes = <<137, 80, 78, 71, 0, 255, 1, 2>>

    assert {:ok, %{path: path, size: 8}} = save_pasted_file("shot.png", Base.encode64(bytes))
    on_exit(fn -> File.rm(path) end)

    assert Path.type(path) == :absolute
    assert Path.extname(path) == ".png"
    assert File.read!(path) == bytes
  end

  test "save_pasted_file derives a safe extension from a MIME hint" do
    assert {:ok, %{path: path}} = save_pasted_file("image/jpeg", Base.encode64("x"))
    on_exit(fn -> File.rm(path) end)
    assert Path.extname(path) == ".jpeg"

    assert {:ok, %{path: weird}} = save_pasted_file("../../etc/passwd", Base.encode64("x"))
    on_exit(fn -> File.rm(weird) end)
    assert Path.extname(weird) == ".png"
    assert Path.dirname(weird) == Path.join(System.tmp_dir!(), "dala-paste")
  end

  test "save_pasted_file rejects invalid base64 and oversized payloads" do
    assert {:error, error} = save_pasted_file("a.png", "not base64!!!")
    assert Exception.message(error) =~ "invalid base64"

    huge = Base.encode64(:binary.copy(<<0>>, 5 * 1024 * 1024 + 1))
    assert {:error, error} = save_pasted_file("a.png", huge)
    assert Exception.message(error) =~ "too large"
  end

  defp delete_entry(path) do
    Dala.Terminal.FileSystem
    |> Ash.ActionInput.for_action(:delete_entry, %{path: path})
    |> Ash.run_action()
  end

  test "delete_entry removes files and directories recursively", %{dir: dir} do
    file = Path.join(dir, "gone.txt")
    File.write!(file, "x")
    assert {:ok, %{path: ^file}} = delete_entry(file)
    refute File.exists?(file)

    sub = Path.join(dir, "sub")
    File.mkdir_p!(Path.join(sub, "deep"))
    File.write!(Path.join(sub, "deep/leaf.txt"), "x")
    assert {:ok, _result} = delete_entry(sub)
    refute File.exists?(sub)
  end

  test "delete_entry errors on missing paths", %{dir: dir} do
    assert {:error, error} = delete_entry(Path.join(dir, "nope"))
    assert Exception.message(error) =~ "cannot delete"
  end

  defp list_files(path) do
    Dala.Terminal.FileSystem
    |> Ash.ActionInput.for_action(:list_files, %{path: path})
    |> Ash.run_action()
  end

  test "list_files walks recursively, skipping hidden and junk dirs", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "src/deep"))
    File.mkdir_p!(Path.join(dir, "node_modules/pkg"))
    File.mkdir_p!(Path.join(dir, ".git"))
    File.write!(Path.join(dir, "top.txt"), "x")
    File.write!(Path.join(dir, "src/deep/leaf.ex"), "x")
    File.write!(Path.join(dir, "node_modules/pkg/skip.js"), "x")
    File.write!(Path.join(dir, ".git/config"), "x")

    assert {:ok, %{root: ^dir, files: files, truncated: false}} = list_files(dir)
    assert "top.txt" in files
    assert "src/deep/leaf.ex" in files
    refute Enum.any?(files, &String.contains?(&1, "node_modules"))
    refute Enum.any?(files, &String.starts_with?(&1, ".git"))
  end

  test "list_files rejects non-directories", %{dir: dir} do
    file = Path.join(dir, "f.txt")
    File.write!(file, "x")
    assert {:error, error} = list_files(file)
    assert Exception.message(error) =~ "not a directory"
  end
end
