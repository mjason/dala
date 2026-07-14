defmodule DalaWeb.VersionControllerTest do
  # async: false — the auth test flips the global :auth_enabled flag.
  use DalaWeb.ConnCase, async: false

  test "GET /version returns the running server version as plain text", %{conn: conn} do
    conn = get(conn, ~p"/version")
    assert text_response(conn, 200) == to_string(Application.spec(:dala, :vsn))
  end

  test "the version matches the one embedded in the SPA page meta", %{conn: conn} do
    version = text_response(get(conn, ~p"/version"), 200)
    html = html_response(get(build_conn(), ~p"/"), 200)
    assert html =~ ~s(name="dala-version" content="#{version}")
  end

  test "stays public when authentication is enabled", %{conn: conn} do
    Application.put_env(:dala, :auth_enabled, true)
    on_exit(fn -> Application.put_env(:dala, :auth_enabled, false) end)

    conn = get(conn, ~p"/version")
    assert text_response(conn, 200) == to_string(Application.spec(:dala, :vsn))
  end
end
