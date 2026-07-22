defmodule Dala.Terminal.Updater do
  @moduledoc """
  RPC surface for the in-app self-upgrade (see `Dala.Updater`).
  """

  use Ash.Resource,
    otp_app: :dala,
    domain: Dala.Terminal,
    extensions: [AshTypescript.Resource]

  typescript do
    type_name "Updater"
  end

  actions do
    action :check_update, :map do
      description "Compare the running version against the latest GitHub release."

      constraints fields: [
                    enabled: [type: :boolean, allow_nil?: false],
                    current: [type: :string, allow_nil?: false],
                    latest: [type: :string],
                    tag: [type: :string],
                    update_available: [type: :boolean, allow_nil?: false],
                    notes_url: [type: :string],
                    legacy_env_config: [type: :boolean, allow_nil?: false]
                  ]

      run fn _input, _context ->
        with {:ok, info} <- Dala.Updater.check() do
          {:ok,
           Map.put(
             info,
             :legacy_env_config,
             Application.get_env(:dala, :legacy_env_config, false)
           )}
        end
      end
    end

    action :apply_update, :map do
      description "Download the latest release, switch to it and restart the daemon."

      argument :attempt_id, :uuid, allow_nil?: false
      argument :expected_target, :string, allow_nil?: false

      constraints fields: [
                    attempt_id: [type: :string, allow_nil?: false],
                    status: [type: :string, allow_nil?: false],
                    updated_to: [type: :string, allow_nil?: false]
                  ]

      run fn input, _context ->
        Dala.Updater.apply_latest(
          input.arguments.attempt_id,
          input.arguments.expected_target
        )
      end
    end

    action :update_status, :map do
      description "Read one update attempt's authoritative background-helper result."

      argument :attempt_id, :uuid, allow_nil?: false

      constraints fields: [
                    attempt_id: [type: :string],
                    status: [type: :string, allow_nil?: false],
                    target: [type: :string],
                    message: [type: :string],
                    rolled_back: [type: :boolean],
                    started_at: [type: :string],
                    completed_at: [type: :string]
                  ]

      run fn input, _context ->
        Dala.Updater.update_result(Map.get(input.arguments, :attempt_id))
      end
    end
  end
end
