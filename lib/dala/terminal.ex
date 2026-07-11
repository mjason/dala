defmodule Dala.Terminal do
  use Ash.Domain, otp_app: :dala, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Dala.Terminal.Session do
      rpc_action :list_sessions, :read
      rpc_action :create_session, :create
      rpc_action :rename_session, :rename
      rpc_action :set_scrollback_limit, :set_scrollback_limit
      rpc_action :agent_commands, :agent_commands
      rpc_action :foreground_app, :foreground_app
      rpc_action :kick_viewers, :kick_viewers
      rpc_action :close_session, :close
      rpc_action :restart_session, :restart
      rpc_action :delete_session, :destroy
    end

    resource Dala.Terminal.FileSystem do
      rpc_action :list_directory, :list_directory
      rpc_action :list_files, :list_files
      rpc_action :read_file, :read_file
      rpc_action :write_file, :write_file
      rpc_action :save_pasted_file, :save_pasted_file
      rpc_action :delete_entry, :delete_entry
    end

    resource Dala.Terminal.Git do
      rpc_action :git_status, :git_status
      rpc_action :git_diff, :git_diff
      rpc_action :git_file_at, :git_file_at
      rpc_action :git_apply_patch, :git_apply_patch
      rpc_action :git_stage, :git_stage
      rpc_action :git_unstage, :git_unstage
      rpc_action :git_discard, :git_discard
      rpc_action :git_commit, :git_commit
      rpc_action :git_log, :git_log
      rpc_action :git_show, :git_show
      rpc_action :git_branches, :git_branches
      rpc_action :git_checkout, :git_checkout
    end

    resource Dala.Terminal.Updater do
      rpc_action :check_update, :check_update
      rpc_action :apply_update, :apply_update
    end
  end

  resources do
    resource Dala.Terminal.Session do
      define :list_sessions, action: :read
      define :get_session, action: :read, get_by: :id
      define :create_session, action: :create
      define :delete_session, action: :destroy
      define :agent_commands, action: :agent_commands, args: [:id]
      define :foreground_app, action: :foreground_app, args: [:id]
      define :kick_viewers, action: :kick_viewers, args: [:id]
      define :mark_running, action: :mark_running
      define :mark_exited, action: :mark_exited
      define :update_cwd, action: :update_cwd
    end

    resource Dala.Terminal.FileSystem
    resource Dala.Terminal.Git
    resource Dala.Terminal.Updater
  end
end
