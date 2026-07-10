defmodule Dala.Terminal.Session.Changes.ApplyScrollbackLimit do
  @moduledoc """
  The scrollback limit sizes the holder's emulator history, which is fixed at
  shell spawn time — persisting the attribute is all there is to do; the new
  value takes effect when the shell is next (re)started.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context), do: changeset
end
