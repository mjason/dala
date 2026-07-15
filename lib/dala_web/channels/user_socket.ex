defmodule DalaWeb.UserSocket do
  use Phoenix.Socket

  channel "terminal:*", DalaWeb.TerminalChannel
  channel "sessions", DalaWeb.SessionsChannel
  channel "settings", DalaWeb.SettingsChannel

  @impl true
  def connect(params, socket, _connect_info) do
    if Dala.Auth.enabled?() do
      with token when is_binary(token) <- params["token"],
           {:ok, user} <- Dala.Auth.verify_bearer_token(token) do
        {:ok, assign(socket, :user_id, user.id)}
      else
        _ -> :error
      end
    else
      {:ok, socket}
    end
  end

  @impl true
  def id(%{assigns: %{user_id: user_id}}), do: "user_socket:#{user_id}"
  def id(_socket), do: nil
end
