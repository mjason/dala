defmodule Dala.Terminal.Session.Changes.ApplyScrollbackLimit do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, session} ->
        Dala.Terminal.Scrollback.set_limit(session.id, session.scrollback_limit)
        {:ok, session}

      _changeset, error ->
        error
    end)
  end
end
