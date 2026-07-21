defmodule DalaWeb.FileControllerTest do
  use DalaWeb.ConnCase, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "dala-file-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "serves a file inline with its MIME type", %{conn: conn, dir: dir} do
    path = Path.join(dir, "page.html")
    File.write!(path, "<h1>hello</h1>")

    conn = get(conn, ~p"/files/raw?#{[path: path]}")

    assert response(conn, 200) == "<h1>hello</h1>"
    assert response_content_type(conn, :html) =~ "text/html"
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "inline"
  end

  test "serves byte ranges for resumable downloads", %{conn: conn, dir: dir} do
    path = Path.join(dir, "range.bin")
    File.write!(path, "0123456789")

    partial = conn |> put_req_header("range", "bytes=2-5") |> get(~p"/files/raw?#{[path: path]}")
    assert response(partial, 206) == "2345"
    assert get_resp_header(partial, "content-range") == ["bytes 2-5/10"]
    assert get_resp_header(partial, "content-length") == ["4"]
    assert get_resp_header(partial, "content-encoding") == []

    suffix =
      build_conn()
      |> put_req_header("range", "bytes=-3")
      |> get(~p"/files/raw?#{[path: path]}")

    assert response(suffix, 206) == "789"

    invalid =
      build_conn()
      |> put_req_header("range", "bytes=20-30")
      |> get(~p"/files/raw?#{[path: path]}")

    assert response(invalid, 416) == ""
    assert get_resp_header(invalid, "content-range") == ["bytes */10"]
  end

  test "streams large text files as gzip when the client accepts it", %{conn: conn, dir: dir} do
    path = Path.join(dir, "large.html")
    content = String.duplicate("<section>highly compressible backtest data</section>\n", 4_000)
    File.write!(path, content)

    conn =
      conn
      |> put_req_header("accept-encoding", "br, gzip, deflate")
      |> get(~p"/files/raw?#{[path: path, download: "1"]}")

    assert get_resp_header(conn, "content-encoding") == ["gzip"]
    assert get_resp_header(conn, "vary") == ["accept-encoding"]
    assert :zlib.gunzip(response(conn, 200)) == content
    assert byte_size(response(conn, 200)) < div(byte_size(content), 10)
  end

  test "does not compress ranges, binary files or an explicitly rejected gzip encoding", %{
    conn: conn,
    dir: dir
  } do
    html = Path.join(dir, "range.html")
    content = String.duplicate("abcdefghij", 500)
    File.write!(html, content)

    ranged =
      conn
      |> put_req_header("accept-encoding", "gzip")
      |> put_req_header("range", "bytes=10-19")
      |> get(~p"/files/raw?#{[path: html]}")

    assert response(ranged, 206) == "abcdefghij"
    assert get_resp_header(ranged, "content-encoding") == []
    assert get_resp_header(ranged, "vary") == ["accept-encoding"]

    rejected =
      build_conn()
      |> put_req_header("accept-encoding", "gzip;q=0, *;q=1")
      |> get(~p"/files/raw?#{[path: html]}")

    assert response(rejected, 200) == content
    assert get_resp_header(rejected, "content-encoding") == []

    binary = Path.join(dir, "large.bin")
    bytes = :crypto.strong_rand_bytes(4_096)
    File.write!(binary, bytes)

    binary_conn =
      build_conn()
      |> put_req_header("accept-encoding", "gzip")
      |> get(~p"/files/raw?#{[path: binary]}")

    assert response(binary_conn, 200) == bytes
    assert get_resp_header(binary_conn, "content-encoding") == []
  end

  test "serves a download with attachment disposition", %{conn: conn, dir: dir} do
    path = Path.join(dir, "data.bin")
    File.write!(path, <<0, 1, 2>>)

    conn = get(conn, ~p"/files/raw?#{[path: path, download: "1"]}")

    assert response(conn, 200) == <<0, 1, 2>>
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment"
  end

  test "404s for missing files and directories", %{conn: conn, dir: dir} do
    assert conn |> get(~p"/files/raw?#{[path: Path.join(dir, "nope")]}") |> response(404)
    assert conn |> get(~p"/files/raw?#{[path: dir]}") |> response(404)
  end

  defp upload_conn(conn, dir, filename, content) do
    tmp = Path.join(System.tmp_dir!(), "upload-src-#{System.unique_integer([:positive])}")
    File.write!(tmp, content)
    on_exit(fn -> File.rm(tmp) end)

    upload = %Plug.Upload{path: tmp, filename: filename, content_type: "application/octet-stream"}
    post(conn, ~p"/files/upload", %{"dir" => dir, "file" => upload})
  end

  test "uploads a file into the directory", %{conn: conn, dir: dir} do
    conn = upload_conn(conn, dir, "notes.txt", "uploaded!")

    assert %{"path" => path, "name" => "notes.txt", "size" => 9} = json_response(conn, 200)
    assert File.read!(path) == "uploaded!"
  end

  test "upload never overwrites — collisions get a suffix", %{conn: conn, dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "original")

    conn = upload_conn(conn, dir, "a.txt", "second")

    assert %{"name" => "a-1.txt", "path" => path} = json_response(conn, 200)
    assert File.read!(path) == "second"
    assert File.read!(Path.join(dir, "a.txt")) == "original"
  end

  test "upload rejects bad directories and names", %{conn: conn, dir: dir} do
    assert conn
           |> upload_conn(Path.join(dir, "missing"), "a.txt", "x")
           |> json_response(400)

    assert %{"error" => _message} =
             build_conn() |> upload_conn(dir, "", "x") |> json_response(400)
  end

  test "upload enforces the configured per-file quota with a clear 413", %{dir: dir} do
    previous = Application.get_env(:dala, :file_limits, %{})
    Application.put_env(:dala, :file_limits, %{drawer_upload_bytes: 1})
    on_exit(fn -> Application.put_env(:dala, :file_limits, previous) end)

    source = Path.join(dir, "source.bin")
    File.write!(source, "xx")

    upload = %Plug.Upload{
      path: source,
      filename: "large.bin",
      content_type: "application/octet-stream"
    }

    conn = DalaWeb.FileController.upload(build_conn(), %{"dir" => dir, "file" => upload})
    assert %{"error" => message} = json_response(conn, 413)
    assert message =~ "max 1 bytes"
    refute File.exists?(Path.join(dir, "large.bin"))
  end

  test "reports the effective browser upload limits", %{conn: conn} do
    previous = Application.get_env(:dala, :file_limits, %{})

    Application.put_env(:dala, :file_limits, %{
      drawer_upload_bytes: 3 * 1024 * 1024,
      browser_attachment_bytes: 7 * 1024 * 1024
    })

    on_exit(fn -> Application.put_env(:dala, :file_limits, previous) end)

    assert %{
             "drawer_upload" => %{"max_bytes" => 3_145_728, "max_label" => "3 MB"},
             "browser_attachment" => %{"max_bytes" => 7_340_032, "max_label" => "7 MB"}
           } =
             conn |> get(~p"/files/limits") |> json_response(200)
  end

  test "terminal attachment multipart upload lands in private managed storage", %{
    conn: conn,
    dir: dir
  } do
    conn = upload_conn_to(conn, "/files/attachment", dir, "screen shot.png", <<1, 2, 3>>)

    assert %{"path" => path, "name" => "screen_shot.png", "size" => 3} =
             json_response(conn, 200)

    assert File.read!(path) == <<1, 2, 3>>
    assert {:ok, %File.Stat{mode: mode, type: :regular}} = File.lstat(path)

    unless Dala.TestPlatform.windows?() do
      assert Bitwise.band(mode, 0o077) == 0
    end

    on_exit(fn -> File.rm_rf(Path.dirname(path)) end)
  end

  test "requires auth when enabled", %{conn: conn, dir: dir} do
    Application.put_env(:dala, :auth_enabled, true)
    on_exit(fn -> Application.put_env(:dala, :auth_enabled, false) end)

    path = Path.join(dir, "secret.txt")
    File.write!(path, "secret")

    conn = get(conn, ~p"/files/raw?#{[path: path]}")
    assert redirected_to(conn) == "/sign-in"
  end

  describe "download token (auth enabled, no session)" do
    setup do
      Application.put_env(:dala, :auth_enabled, true)
      # Token serving is tied to the live MCP read capability.
      Dala.Settings.Mcp.current()
      Dala.Settings.Mcp.set_terminal_access(true, false)

      on_exit(fn ->
        Application.put_env(:dala, :auth_enabled, false)
        Dala.Settings.Mcp.set_terminal_access(false, false)
      end)

      :ok
    end

    test "a valid path-scoped token downloads the file without a session", %{dir: dir} do
      path = Path.join(dir, "report.csv")
      File.write!(path, "a,b,c")
      token = DalaWeb.FileDownloadToken.sign(path)

      conn =
        build_conn()
        |> get(~p"/files/raw?#{[path: path, download: "1", token: token]}")

      assert response(conn, 200) == "a,b,c"
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
    end

    test "turning MCP read access OFF revokes an already-minted token", %{dir: dir} do
      path = Path.join(dir, "secret.env")
      File.write!(path, "KEY=1")
      token = DalaWeb.FileDownloadToken.sign(path)

      # Works while read is on…
      assert build_conn()
             |> get(~p"/files/raw?#{[path: path, token: token]}")
             |> response(200) == "KEY=1"

      # …and stops the instant read access is revoked.
      Dala.Settings.Mcp.set_terminal_access(false, false)
      conn = build_conn() |> get(~p"/files/raw?#{[path: path, token: token]}")
      assert response(conn, 401) =~ "token"
    end

    test "a token for a DIFFERENT path is rejected with 401", %{dir: dir} do
      allowed = Path.join(dir, "allowed.txt")
      other = Path.join(dir, "other.txt")
      File.write!(allowed, "ok")
      File.write!(other, "SECRET")
      token = DalaWeb.FileDownloadToken.sign(allowed)

      # The token names `allowed` but the request asks for `other`.
      conn = build_conn() |> get(~p"/files/raw?#{[path: other, token: token]}")
      assert response(conn, 401) =~ "token"
    end

    test "a tampered/garbage token is rejected with 401", %{dir: dir} do
      path = Path.join(dir, "x.txt")
      File.write!(path, "x")
      conn = build_conn() |> get(~p"/files/raw?#{[path: path, token: "not-a-real-token"]}")
      assert response(conn, 401) =~ "token"
    end
  end

  defp upload_conn_to(conn, route, dir, filename, content) do
    tmp = Path.join(dir, "attachment-source-#{System.unique_integer([:positive])}")
    File.write!(tmp, content)
    upload = %Plug.Upload{path: tmp, filename: filename, content_type: "image/png"}
    post(conn, route, %{"file" => upload})
  end
end
