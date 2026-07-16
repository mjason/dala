defmodule Dala.Mcp.FileToolsTest do
  use Dala.DataCase, async: false

  alias Dala.Mcp.{FileTools, Registry}

  setup do
    Dala.Settings.Mcp.current()

    dir = Path.join(System.tmp_dir!(), "dala-filetool-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  test "with read access: returns an absolute, token-authenticated URL and metadata", %{dir: dir} do
    Dala.Settings.Mcp.set_terminal_access(true, false)
    path = Path.join(dir, "data.csv")
    File.write!(path, "x,y,z")

    assert {:ok, result} =
             FileTools.call("get_download_url", %{"path" => path}, %{base_url: "http://host:4400"})

    assert result.path == path
    assert result.filename == "data.csv"
    assert result.bytes == 5
    assert result.contentType =~ "csv"
    assert result.expiresInSeconds == DalaWeb.FileDownloadToken.max_age()

    assert String.starts_with?(result.url, "http://host:4400/files/raw?")
    %{query: query} = URI.parse(result.url)
    params = URI.decode_query(query)
    assert params["path"] == path
    assert params["download"] == "1"
    # The embedded token unlocks exactly this path.
    assert DalaWeb.FileDownloadToken.valid_for?(params["token"], path)
    refute DalaWeb.FileDownloadToken.valid_for?(params["token"], path <> ".other")
  end

  test "is permission-gated in both discovery and execution", %{dir: dir} do
    path = Path.join(dir, "f.txt")
    File.write!(path, "f")

    Dala.Settings.Mcp.set_terminal_access(false, false)
    refute "get_download_url" in Enum.map(Registry.tools(), & &1["name"])
    assert {:error, message} = FileTools.call("get_download_url", %{"path" => path}, %{})
    assert message =~ "disabled"

    Dala.Settings.Mcp.set_terminal_access(true, false)
    assert "get_download_url" in Enum.map(Registry.tools(), & &1["name"])
  end

  test "rejects directories, missing files and a missing path", %{dir: dir} do
    Dala.Settings.Mcp.set_terminal_access(true, false)

    assert {:error, msg1} = FileTools.call("get_download_url", %{"path" => dir}, %{})
    assert msg1 =~ "not a regular file"

    assert {:error, msg2} =
             FileTools.call("get_download_url", %{"path" => Path.join(dir, "nope")}, %{})

    assert msg2 =~ "cannot read"

    assert {:error, msg3} = FileTools.call("get_download_url", %{}, %{})
    assert msg3 =~ "path is required"
  end

  test "falls back to the endpoint URL when no base_url is threaded", %{dir: dir} do
    Dala.Settings.Mcp.set_terminal_access(true, false)
    path = Path.join(dir, "g.txt")
    File.write!(path, "g")

    assert {:ok, result} = FileTools.call("get_download_url", %{"path" => path}, %{})
    assert String.starts_with?(result.url, DalaWeb.Endpoint.url() <> "/files/raw?")
  end
end
