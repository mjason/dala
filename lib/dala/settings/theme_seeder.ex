defmodule Dala.Settings.ThemeSeeder do
  @moduledoc """
  Boots the six built-in theme presets into the DB at startup.

  Idempotent: `Dala.Settings.Theme.Presets.ensure!/0` upserts each preset by
  its fixed id, so every boot simply refreshes the shipped colours and adds
  nothing on a database that already has them. Runs after the Endpoint (the
  seed create actions publish `theme_created`, which broadcasts through it) and
  after migrations. A failure here (e.g. a not-yet-migrated table on a broken
  deploy) is logged, not fatal — the app still boots without presets.
  """

  require Logger

  def child_spec(_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :transient}
  end

  @doc "Runs synchronously during supervision-tree startup."
  def start_link do
    try do
      Dala.Settings.Theme.ensure_builtin_presets()
    rescue
      error ->
        Logger.warning("could not seed built-in theme presets: #{Exception.message(error)}")
    end

    :ignore
  end
end
