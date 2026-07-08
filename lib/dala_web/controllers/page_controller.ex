defmodule DalaWeb.PageController do
  use DalaWeb, :controller

  def index(conn, _params) do
    user = conn.assigns[:current_user]

    conn
    |> put_root_layout(html: {DalaWeb.Layouts, :spa_root})
    |> assign(:user_email, user && to_string(user.email))
    |> assign(:socket_token, user && Dala.Auth.bearer_token(conn))
    |> render(:index)
  end
end
