defmodule Dala.Terminal.Session.Changes.CloseAttachedShells do
  @moduledoc false
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_transaction(changeset, fn changeset ->
      # A tab must never outlive the session it is attached to: its holder
      # would keep a shell (and whatever server it is running) alive with no
      # way left to reach it. Children cannot nest, so this does not recurse.
      changeset.data.id
      |> attached_shells()
      |> Enum.each(&Dala.Terminal.delete_session/1)

      changeset
    end)
  end

  @doc false
  def attached_shells(parent_id) do
    Dala.Terminal.Session
    |> Ash.Query.filter(parent_id == ^parent_id)
    |> Ash.read!()
  rescue
    _error -> []
  end
end
