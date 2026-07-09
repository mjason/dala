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

  test "requires auth when enabled", %{conn: conn, dir: dir} do
    Application.put_env(:dala, :auth_enabled, true)
    on_exit(fn -> Application.put_env(:dala, :auth_enabled, false) end)

    path = Path.join(dir, "secret.txt")
    File.write!(path, "secret")

    conn = get(conn, ~p"/files/raw?#{[path: path]}")
    assert redirected_to(conn) == "/sign-in"
  end
end
