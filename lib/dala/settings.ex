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

    resource Dala.Settings.Theme do
      rpc_action :list_themes, :list
      rpc_action :get_theme, :get, not_found_error?: false
      rpc_action :create_theme, :create
      rpc_action :update_theme, :update
      rpc_action :delete_theme, :destroy
    end

    # For the WEB Settings panel only (via the auth-gated /rpc/run). These are
    # DELIBERATELY excluded from the MCP tool registry — an AI on /mcp must
    # never be able to toggle MCP or read/rotate its own token. See
    # `Dala.Mcp.Registry`'s `@self_managed_resources`.
    resource Dala.Settings.Mcp do
      rpc_action :mcp_settings, :current
      rpc_action :set_mcp_enabled, :set_enabled
      rpc_action :regenerate_mcp_token, :regenerate_token
    end
  end

  resources do
    resource Dala.Settings.Speech
    resource Dala.Settings.Theme
    resource Dala.Settings.Mcp
  end
end
