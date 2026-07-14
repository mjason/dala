defmodule Dala.Settings do
  @moduledoc """
  Server-side settings shared across every device that talks to this dala
  instance. Browser localStorage holds only what is genuinely per-device
  (theme, keybindings, the microphone id); anything a user would expect to
  "just be there" on their phone after configuring it on their laptop —
  like the speech transcription endpoint — lives here.

  When authentication is enabled each user gets their own row; with
  authentication off (the default single-user install) everyone shares the
  one row whose `user_id` is `nil`.
  """

  use Ash.Domain, otp_app: :dala, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Dala.Settings.Speech do
      rpc_action :speech_settings, :current
      rpc_action :set_speech_settings, :save
    end
  end

  resources do
    resource Dala.Settings.Speech
  end
end
