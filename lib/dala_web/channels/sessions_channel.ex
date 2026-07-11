defmodule DalaWeb.SessionsChannel do
  @moduledoc """
  Lobby channel broadcasting terminal-session lifecycle events, used by the
  sidebar to keep the session list current.
  """

  use Phoenix.Channel
  use AshTypescript.TypedChannel

  typed_channel do
    topic "sessions"

    resource Dala.Terminal.Session do
      publish :session_created
      publish :session_updated
      publish :session_deleted
      publish :agent_event
    end
  end

  @impl true
  def join("sessions", _payload, socket) do
    {:ok, socket}
  end
end
