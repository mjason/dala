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
                    notes_url: [type: :string]
                  ]

      run fn _input, _context ->
        Dala.Updater.check()
      end
    end

    action :apply_update, :map do
      description "Download the latest release, switch to it and restart the daemon."

      constraints fields: [
                    updated_to: [type: :string, allow_nil?: false]
                  ]

      run fn _input, _context ->
        Dala.Updater.apply_latest()
      end
    end
  end
end
