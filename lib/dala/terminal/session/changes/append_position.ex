defmodule Dala.Terminal.Session.Changes.AppendPosition do
  @moduledoc "New sessions land at the end of the sidebar."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      Ash.Changeset.force_change_attribute(
        changeset,
        :position,
        Dala.Terminal.Session.Position.append_position()
      )
    end)
  end
end
