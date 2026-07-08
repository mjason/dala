defmodule Dala.Terminal.Boot do
  @moduledoc """
  Marks sessions that were running before a BEAM restart as exited — their
  PTYs died with the old VM. Scrollback survives in DETS, and the user can
  restart such a session from the UI.
  """

  require Ash.Query

  def child_spec(_arg) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :transient}
  end

  @doc "Runs synchronously during supervision-tree startup."
  def start_link do
    run()
    :ignore
  end

  def run do
    Dala.Terminal.Session
    |> Ash.Query.filter(status == :running)
    |> Ash.read!()
    |> Enum.each(fn session ->
      Dala.Terminal.mark_exited!(session, %{exit_code: nil})
    end)
  end
end
