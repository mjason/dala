defmodule Dala.Agent do
  use Ash.Domain, otp_app: :dala, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Dala.Agent.Session do
      rpc_action :list_agent_sessions, :read
      rpc_action :create_agent_session, :create
      rpc_action :rename_agent_session, :rename
      rpc_action :delete_agent_session, :destroy
      rpc_action :prompt_agent, :prompt
      rpc_action :cancel_agent, :cancel
      rpc_action :respond_agent_permission, :respond_permission
    end
  end

  resources do
    resource Dala.Agent.Session do
      define :get_session, action: :read, get_by: :id
      define :mark_ready, action: :mark_ready
      define :mark_exited, action: :mark_exited
    end
  end
end
