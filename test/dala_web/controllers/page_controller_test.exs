defmodule DalaWeb.PageControllerTest do
  use DalaWeb.ConnCase

  test "GET / serves the terminal SPA", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ ~s(id="app")
    assert html =~ ~s(name="auth-enabled" content="false")
  end
end
