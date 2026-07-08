defmodule DalaWeb.AuthController do
  use DalaWeb, :controller
  use AshAuthentication.Phoenix.Controller

  def success(conn, _activity, user, _token) do
    return_to = get_session(conn, :return_to) || ~p"/"

    message = "You are now signed in"

    conn
    |> delete_session(:return_to)
    |> store_in_session(user)
    # If your resource has a different name, update the assign name here (i.e :current_admin)
    |> assign(:current_user, user)
    |> put_flash(:info, message)
    |> redirect(to: return_to)
  end

  def failure(conn, _activity, _reason) do
    conn
    |> put_flash(:error, "Incorrect email or password")
    |> redirect(to: ~p"/sign-in")
  end

  def sign_out(conn, _params) do
    return_to = get_session(conn, :return_to) || ~p"/"

    conn
    # Revoke the bearer token too, so websocket access ends with the session.
    |> revoke_session_tokens(:dala)
    |> clear_session(:dala)
    |> put_flash(:info, "You are now signed out")
    |> redirect(to: return_to)
  end
end
