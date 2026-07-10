defmodule Dala.Terminal.Session.Changes.CleanupSession do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_transaction(fn changeset ->
      # Stop the shell and wait for the exit to be recorded, so the holder's
      # leftover files below are final before we remove them.
      Dala.Terminal.Server.shutdown_and_wait(changeset.data.id)
      changeset
    end)
    |> Ash.Changeset.after_transaction(fn
      changeset, {:ok, result} ->
        id = to_string(changeset.data.id)
        _ = File.rm(Dala.Terminal.Holder.exit_path(id))
        _ = File.rm(Dala.Terminal.Holder.final_path(id))
        {:ok, result}

      _changeset, error ->
        error
    end)
  end
end
