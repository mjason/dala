defmodule DalaWeb.PageController do
  use DalaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def index conn, _params do
    conn |> put_root_layout(html: {DalaWeb.Layouts, :spa_root}) |> render(:index)
  end
end
