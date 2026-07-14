defmodule DalaWeb.PageControllerTest do
  use DalaWeb.ConnCase

  test "GET / serves the terminal SPA", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(id="app")
    assert html =~ ~s(name="auth-enabled" content="false")
    assert html =~ ~s(src="/assets/theme.js")
    refute html =~ ~s(<html lang="en" data-theme="dark">)
  end
end
