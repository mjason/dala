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
end
