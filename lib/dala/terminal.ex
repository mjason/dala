defmodule Dala.Terminal do
  use Ash.Domain, otp_app: :dala, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Dala.Terminal.Session do
      rpc_action :list_sessions, :read
      rpc_action :create_session, :create
      rpc_action :rename_session, :rename
      rpc_action :set_scrollback_limit, :set_scrollback_limit
      rpc_action :close_session, :close
      rpc_action :restart_session, :restart
      rpc_action :delete_session, :destroy
    end

    resource Dala.Terminal.FileSystem do
      rpc_action :list_directory, :list_directory
      rpc_action :read_file, :read_file
    end
  end

  resources do
    resource Dala.Terminal.Session do
      define :list_sessions, action: :read
      define :get_session, action: :read, get_by: :id
      define :create_session, action: :create
      define :delete_session, action: :destroy
      define :mark_running, action: :mark_running
      define :mark_exited, action: :mark_exited
      define :update_cwd, action: :update_cwd
    end

    resource Dala.Terminal.FileSystem
  end
end
