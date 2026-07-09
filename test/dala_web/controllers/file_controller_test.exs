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
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "inline"
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

  test "requires auth when enabled", %{conn: conn, dir: dir} do
    Application.put_env(:dala, :auth_enabled, true)
    on_exit(fn -> Application.put_env(:dala, :auth_enabled, false) end)

    path = Path.join(dir, "secret.txt")
    File.write!(path, "secret")

    conn = get(conn, ~p"/files/raw?#{[path: path]}")
    assert redirected_to(conn) == "/sign-in"
  end
end
