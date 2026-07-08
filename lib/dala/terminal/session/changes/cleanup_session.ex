defmodule Dala.Terminal.Session.Changes.CleanupSession do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_transaction(fn changeset ->
      # Stop the shell and wait for the exit to be recorded, so no final
      # output lands in the scrollback cache after it is cleared below.
      Dala.Terminal.Server.shutdown_and_wait(changeset.data.id)
      changeset
    end)
    |> Ash.Changeset.after_transaction(fn
      changeset, {:ok, result} ->
        Dala.Terminal.Scrollback.clear(changeset.data.id)
        {:ok, result}

      _changeset, error ->
        error
    end)
  end
end
