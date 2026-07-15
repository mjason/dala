defmodule DalaWeb.SettingsChannel do
  @moduledoc """
  Lobby channel broadcasting server-side settings lifecycle events. Currently
  the custom-theme library: `theme_created`/`theme_updated`/`theme_deleted`,
  used to keep the theme picker/editor in sync across a user's devices.

  The topic is a single shared `"settings"` (like the `"sessions"` lobby), not
  per-user; every payload carries `ownerId`, so a client filters to its own +
  the global/built-in library itself.
  """

  use Phoenix.Channel
  use AshTypescript.TypedChannel

  typed_channel do
    topic "settings"

    resource Dala.Settings.Theme do
      publish :theme_created
      publish :theme_updated
      publish :theme_deleted
    end
  end

  @impl true
  def join("settings", _payload, socket) do
    # Hand the client its own owner id so a device whose library is still only
    # the global presets can recognise its first own theme_created event (whose
    # ownerId is the actor id, matching nothing already visible). Anonymous /
    # auth-off sockets fall back to the global sentinel.
    owner_id = socket.assigns[:user_id] || Dala.Settings.Theme.global_id()
    {:ok, %{owner_id: owner_id}, socket}
  end
end
