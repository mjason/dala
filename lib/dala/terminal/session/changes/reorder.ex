defmodule Dala.Terminal.Session.Changes.Reorder do
  @moduledoc """
  Computes the moved session's new float position from the `before_id`
  argument (see `Dala.Terminal.Session.Position`). Runs in `before_action`
  so neighbours are read at write time, keeping racing reorders sane. A
  renormalization's nested updates run inside this transaction, so their
  notifications are RETURNED from the hook — Ash then publishes the
  renumbered rows' `session_updated` events after commit instead of
  dropping them ("missed notifications").
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.get_argument(changeset, :before_id) do
        # "Before itself" is a no-op, not a move to the end.
        before_id when before_id == changeset.data.id ->
          changeset

        before_id ->
          {position, notifications} =
            Dala.Terminal.Session.Position.reorder_position(changeset.data.id, before_id)

          {Ash.Changeset.force_change_attribute(changeset, :position, position),
           %{notifications: notifications}}
      end
    end)
  end
end
